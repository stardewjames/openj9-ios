package bench;

import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.ThreadLocalRandom;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReference;

/** Runs the actual bundled Suwayomi server in this VM and exercises its GraphQL API. */
public final class SuwayomiMain {
    private static native void startSampling();
    private static native void stopSampling();
    private static final byte[] QUERY = "{\"query\":\"query { categories(first: 20) { totalCount nodes { id name } } }\"}".getBytes(StandardCharsets.UTF_8);

    private static int setting(String name, int fallback, int max) {
        String value = System.getenv(name);
        int result = value == null || value.isEmpty() ? fallback : Integer.parseInt(value);
        if (result < 1 || result > max) throw new IllegalArgumentException(name + " out of range");
        return result;
    }

    private static void request(int port) throws Exception {
        HttpURLConnection connection = (HttpURLConnection) new URL("http://127.0.0.1:" + port + "/api/graphql").openConnection();
        try {
            connection.setConnectTimeout(5000);
            connection.setReadTimeout(30000);
            connection.setRequestMethod("POST");
            connection.setRequestProperty("Content-Type", "application/json");
            connection.setDoOutput(true);
            try (OutputStream output = connection.getOutputStream()) { output.write(QUERY); }
            int status = connection.getResponseCode();
            try (InputStream input = status == 200 ? connection.getInputStream() : connection.getErrorStream()) {
                String response = input == null ? "" : new String(input.readAllBytes(), StandardCharsets.UTF_8);
                if (status != 200 || response.contains("\"errors\"") || !response.contains("\"categories\"")) {
                    throw new IllegalStateException("GraphQL status=" + status + " response=" + response);
                }
            }
        } finally { connection.disconnect(); }
    }

    public static void main(String[] args) throws Exception {
        String mode = args[0];
        int seconds = setting("BENCH_DURATION", 60, 86400);
        if (mode.equals("idle")) {
            System.out.println("IDLE_BEGIN target=jvm");
            startSampling();
            try { Thread.sleep(seconds * 1000L); } finally { stopSampling(); }
            System.out.println("BENCH_OK");
            return;
        }
        int port = setting("SUWAYOMI_PORT", 4567, 65535);
        Path root = Path.of(System.getProperty("java.io.tmpdir"), "suwayomi-benchmark");
        Files.createDirectories(root);
        System.setProperty("suwayomi.tachidesk.config.server.rootDir", root.toString());
        System.setProperty("suwayomi.tachidesk.config.server.ip", "127.0.0.1");
        System.setProperty("suwayomi.tachidesk.config.server.port", Integer.toString(port));
        System.setProperty("suwayomi.tachidesk.config.server.initialOpenInBrowserEnabled", "false");
        System.setProperty("suwayomi.tachidesk.config.server.kcefEnabled", "false");
        System.setProperty("suwayomi.tachidesk.config.server.systemTrayEnabled", "false");
        AtomicReference<Throwable> startupFailure = new AtomicReference<>();
        long start = System.nanoTime();
        Thread server = new Thread(() -> {
            try { Class.forName("suwayomi.tachidesk.MainKt").getMethod("main").invoke(null); }
            catch (Throwable t) { startupFailure.set(t); }
        }, "suwayomi-startup");
        server.setDaemon(true);
        server.start();
        long deadline = System.nanoTime() + setting("SUWAYOMI_STARTUP_TIMEOUT", 180, 3600) * 1_000_000_000L;
        Exception last = null;
        while (true) {
            if (startupFailure.get() != null) throw new IllegalStateException("Suwayomi startup failed", startupFailure.get());
            if (!server.isAlive()) {
                try { request(port); break; } catch (Exception e) { last = e; }
            }
            if (System.nanoTime() >= deadline) throw new IllegalStateException("Suwayomi readiness timed out", last);
            Thread.sleep(500);
        }
        System.out.printf("SUWAYOMI_READY startup_ms=%.3f port=%d root=%s%n", (System.nanoTime()-start)/1e6, port, root);
        if (mode.equals("suwayomi-idle")) {
            System.out.println("IDLE_BEGIN target=suwayomi");
            startSampling();
            try { Thread.sleep(seconds * 1000L); } finally { stopSampling(); }
        } else if (mode.equals("suwayomi")) {
            int concurrency = setting("SUWAYOMI_CONCURRENCY", 4, 64);
            List<Long> latencies = new ArrayList<>();
            AtomicLong completed = new AtomicLong();
            AtomicReference<Throwable> failure = new AtomicReference<>();
            long end = System.nanoTime() + seconds * 1_000_000_000L;
            List<Thread> workers = new ArrayList<>();
            System.out.printf("SUWAYOMI_BEGIN duration_s=%d concurrency=%d%n", seconds, concurrency);
            startSampling();
            long[] finished = new long[1];
            try {
                for (int i = 0; i < concurrency; i++) {
                    Thread worker = new Thread(() -> {
                        while (System.nanoTime() < end && failure.get() == null) {
                            long before = System.nanoTime();
                            try {
                                request(port);
                                long latency = System.nanoTime() - before;
                                synchronized (latencies) {
                                    long seen = completed.incrementAndGet();
                                    if (latencies.size() < 100000) latencies.add(latency);
                                    else {
                                        long slot = ThreadLocalRandom.current().nextLong(seen);
                                        if (slot < latencies.size()) latencies.set((int)slot, latency);
                                    }
                                }
                            }
                            catch (Throwable t) { failure.compareAndSet(null, t); }
                        }
                    }, "suwayomi-client-" + i);
                    workers.add(worker);
                    worker.start();
                }
                for (Thread worker : workers) worker.join();
                finished[0] = System.nanoTime();
            } finally { stopSampling(); }
            if (failure.get() != null) throw new IllegalStateException("Suwayomi request failed", failure.get());
            if (latencies.isEmpty()) throw new IllegalStateException("no completed requests");
            Collections.sort(latencies);
            double elapsed = (finished[0] - (end - seconds * 1_000_000_000L)) / 1e9;
            System.out.printf("SUWAYOMI_RESULT requests=%d latency_samples=%d elapsed_s=%.3f requests_per_s=%.3f p50_ms=%.3f p95_ms=%.3f%n", completed.get(), latencies.size(), elapsed, completed.get()/elapsed, latencies.get((latencies.size()-1)/2)/1e6, latencies.get((int)((latencies.size()-1)*0.95))/1e6);
        } else throw new IllegalArgumentException("unknown mode " + mode);
        System.out.println("BENCH_OK");
    }
}
