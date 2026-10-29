package bench;

import java.io.*;
import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;
import java.lang.invoke.MethodType;
import java.lang.reflect.*;
import java.math.BigDecimal;
import java.math.BigInteger;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.security.*;
import java.text.NumberFormat;
import java.time.*;
import java.time.format.DateTimeFormatter;
import java.util.*;
import java.util.concurrent.*;
import java.util.regex.Pattern;
import java.util.zip.*;
import javax.net.ssl.SSLContext;

/**
 * Feature probes. Each line answers "does this runtime actually deliver this
 * API" rather than "does it compile", so the same jar can be compared across
 * VM implementations and class-library majors.
 */
public final class Compatibility {
    public interface Probe {
        String check() throws Throwable;
    }

    public record Result(String name, String status, String detail) {}

    sealed interface Shape permits Circle, Square {}
    record Circle(int radius) implements Shape {}
    record Square(int side) implements Shape {}

    private static final LinkedHashMap<String, Probe> PROBES = new LinkedHashMap<>();

    static {
        // Language-level features the class library has to support.
        PROBES.put("records", () -> {
            record Point(int x, int y) {}
            Point point = new Point(1, 2);
            boolean record = point.getClass().isRecord()
                && point.getClass().getRecordComponents().length == 2
                && point.equals(new Point(1, 2));
            return record ? "ok " + point : "record semantics differ";
        });
        PROBES.put("sealed", () -> {
            boolean sealed = Shape.class.isSealed() && Shape.class.getPermittedSubclasses().length == 2;
            return sealed ? "ok" : "sealed metadata missing";
        });
        PROBES.put("patternSwitch", () -> {
            Object value = new Circle(2);
            String text = switch (value) {
                case Circle circle -> "circle" + circle.radius();
                case Square square -> "square" + square.side();
                default -> "other";
            };
            return text.equals("circle2") ? "ok " + text : "unexpected " + text;
        });
        PROBES.put("textBlocks", () -> {
            String text = """
                line1
                line2""";
            return text.equals("line1\nline2") ? "ok" : "text block mismatch";
        });

        // Core library behaviour.
        PROBES.put("stringConcatIndy", () -> {
            int value = 42;
            String text = "value=" + value + "/end";
            return text.equals("value=42/end") ? "ok" : "concat mismatch: " + text;
        });
        PROBES.put("methodHandles", () -> {
            MethodHandle handle = MethodHandles.lookup()
                .findStatic(Integer.class, "sum", MethodType.methodType(int.class, int.class, int.class));
            int sum = (int) handle.invokeExact(20, 22);
            return sum == 42 ? "ok" : "handle result " + sum;
        });
        PROBES.put("reflection", () -> {
            Field field = Compatibility.class.getDeclaredField("SECRET");
            field.setAccessible(true);
            return "ok " + field.get(null);
        });
        PROBES.put("dynamicProxy", () -> {
            List<String> list = (List<String>) Proxy.newProxyInstance(
                Compatibility.class.getClassLoader(), new Class<?>[] {List.class},
                (proxy, method, args) -> method.getName().equals("size") ? 7 : null);
            return list.size() == 7 ? "ok" : "proxy failed";
        });
        PROBES.put("serialization", () -> {
            ByteArrayOutputStream bytes = new ByteArrayOutputStream();
            try (ObjectOutputStream out = new ObjectOutputStream(bytes)) {
                out.writeObject(new ArrayList<>(List.of("a", "b")));
            }
            try (ObjectInputStream in = new ObjectInputStream(new ByteArrayInputStream(bytes.toByteArray()))) {
                Object back = in.readObject();
                return back.equals(List.of("a", "b")) ? "ok" : "round trip mismatch";
            }
        });
        PROBES.put("bigNumbers", () -> {
            BigInteger big = new BigInteger("12345678901234567890").multiply(BigInteger.TEN);
            BigDecimal decimal = new BigDecimal("0.1").add(new BigDecimal("0.2"));
            boolean ok = big.toString().equals("123456789012345678900")
                && decimal.compareTo(new BigDecimal("0.3")) == 0;
            return ok ? "ok" : "big number mismatch";
        });
        PROBES.put("regex", () -> {
            var matcher = Pattern.compile("(?<word>OpenJ9)-(?<version>\\d+)").matcher("OpenJ9-21");
            return matcher.matches() ? "ok " + matcher.group("version") : "regex failed";
        });
        PROBES.put("timeZones", () -> {
            ZonedDateTime ny = Instant.parse("2024-07-01T12:00:00Z").atZone(ZoneId.of("America/New_York"));
            boolean ok = ny.getHour() == 8 && ny.getOffset().equals(ZoneOffset.ofHours(-4))
                && DateTimeFormatter.ISO_LOCAL_DATE.format(ny).equals("2024-07-01");
            return ok ? "ok" : "time zone data missing";
        });
        PROBES.put("locales", () -> {
            String formatted = String.format(Locale.GERMANY, "%.2f", 1234.5);
            String currency = NumberFormat.getCurrencyInstance(Locale.US).format(12.5);
            return formatted.equals("1234,50") && currency.contains("12.50")
                ? "ok" : "locale data mismatch: " + formatted + " / " + currency;
        });
        PROBES.put("charsets", () -> {
            String text = "Hello iOS — 日本語 🌍";
            byte[] utf8 = text.getBytes(StandardCharsets.UTF_8);
            boolean ok = new String(utf8, StandardCharsets.UTF_8).equals(text)
                && utf8.length > text.length();
            return ok ? "ok " + utf8.length + " bytes" : "utf-8 mismatch";
        });
        PROBES.put("fileIO", () -> {
            Path file = Files.createTempFile("bench-probe", ".txt");
            try {
                Files.writeString(file, "data");
                return Files.readString(file).equals("data") ? "ok " + file.getParent() : "read mismatch";
            } finally {
                Files.deleteIfExists(file);
            }
        });
        PROBES.put("zip", () -> {
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            try (ZipOutputStream zip = new ZipOutputStream(out)) {
                zip.putNextEntry(new ZipEntry("a.txt"));
                zip.write("payload".getBytes(StandardCharsets.UTF_8));
                zip.closeEntry();
            }
            try (ZipInputStream zip = new ZipInputStream(new ByteArrayInputStream(out.toByteArray()))) {
                zip.getNextEntry();
                return new String(zip.readAllBytes(), StandardCharsets.UTF_8).equals("payload")
                    ? "ok" : "zip mismatch";
            }
        });
        PROBES.put("gzip", () -> {
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            try (GZIPOutputStream gzip = new GZIPOutputStream(out)) {
                gzip.write("payload".getBytes(StandardCharsets.UTF_8));
            }
            try (GZIPInputStream gzip = new GZIPInputStream(new ByteArrayInputStream(out.toByteArray()))) {
                return new String(gzip.readAllBytes(), StandardCharsets.UTF_8).equals("payload")
                    ? "ok" : "gzip mismatch";
            }
        });
        PROBES.put("digest", () -> {
            byte[] digest = MessageDigest.getInstance("SHA-256").digest("abc".getBytes(StandardCharsets.UTF_8));
            String hex = HexFormat.of().formatHex(digest);
            return hex.equals("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
                ? "ok" : "sha-256 mismatch";
        });
        PROBES.put("secureRandom", () -> {
            byte[] first = new byte[32];
            byte[] second = new byte[32];
            new SecureRandom().nextBytes(first);
            new SecureRandom().nextBytes(second);
            return Arrays.equals(first, second) ? "identical output" : "ok";
        });
        PROBES.put("keyStore", () -> {
            KeyStore store = KeyStore.getInstance(KeyStore.getDefaultType());
            store.load(null, null);
            return "ok " + KeyStore.getDefaultType();
        });
        PROBES.put("tls", () -> {
            SSLContext context = SSLContext.getInstance("TLS");
            context.init(null, null, null);
            return "ok " + context.getProtocol();
        });
        PROBES.put("threads", () -> {
            long[] total = {0};
            Thread thread = new Thread(() -> total[0] = 42, "bench-thread");
            thread.start();
            thread.join();
            return total[0] == 42 ? "ok" : "thread result " + total[0];
        });
        PROBES.put("executors", () -> {
            try (ExecutorService executor = Executors.newFixedThreadPool(2)) {
                Future<Integer> future = executor.submit(() -> 6 * 7);
                return future.get(30, TimeUnit.SECONDS) == 42 ? "ok" : "executor result";
            }
        });
        PROBES.put("completableFuture", () -> {
            int value = CompletableFuture.supplyAsync(() -> 21).thenApply(x -> x * 2).get(30, TimeUnit.SECONDS);
            return value == 42 ? "ok" : "cf result " + value;
        });
        PROBES.put("resources", () -> {
            try (InputStream stream = String.class.getResourceAsStream("/java/lang/Object.class")) {
                return stream != null && stream.read() >= 0 ? "ok" : "class resource missing";
            }
        });
        PROBES.put("stackTrace", () -> {
            try {
                throw new IllegalStateException("probe");
            } catch (IllegalStateException expected) {
                StringWriter trace = new StringWriter();
                expected.printStackTrace(new PrintWriter(trace));
                return trace.toString().contains("IllegalStateException") ? "ok" : "trace incomplete";
            }
        });

        // Optional modules: absent is a SKIP, not a failure. Everything here is
        // reached through reflection so the jar never links against java.desktop.
        PROBES.put("java.desktop", () -> {
            Class<?> environment = Class.forName("java.awt.GraphicsEnvironment");
            boolean headless = (boolean) environment.getMethod("isHeadless").invoke(null);
            Class<?> image = Class.forName("java.awt.image.BufferedImage");
            Object raster = image.getConstructor(int.class, int.class, int.class)
                .newInstance(8, 8, image.getField("TYPE_INT_ARGB").getInt(null));
            Class<?> rendered = Class.forName("java.awt.image.RenderedImage");
            Class<?> imageIO = Class.forName("javax.imageio.ImageIO");
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            boolean written = (boolean) imageIO
                .getMethod("write", rendered, String.class, OutputStream.class)
                .invoke(null, raster, "png", out);
            return (headless ? "headless, " : "display, ") + "png=" + written + ", " + out.size() + " bytes";
        });
    }

    private static final String SECRET = "visible";

    private Compatibility() {}

    public static List<Result> run(java.util.function.Consumer<Result> sink) {
        List<Result> results = new ArrayList<>();
        for (Map.Entry<String, Probe> entry : PROBES.entrySet()) {
            Result result;
            try {
                result = new Result(entry.getKey(), "OK", entry.getValue().check());
            } catch (ClassNotFoundException | NoClassDefFoundError absent) {
                result = new Result(entry.getKey(), "SKIP", String.valueOf(absent.getMessage()));
            } catch (Throwable failure) {
                result = new Result(entry.getKey(), "FAIL", failure.toString());
            }
            results.add(result);
            sink.accept(result);
        }
        return results;
    }

    /** Probes that only need java.base; useful when the class library is trimmed. */
    public static boolean isOptional(String name) {
        return name.equals("java.desktop");
    }
}
