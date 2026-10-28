import java.io.*;
import java.math.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.security.*;
import java.time.*;
import java.time.format.DateTimeFormatter;
import java.util.*;
import java.util.concurrent.*;
import java.util.logging.Logger;
import java.util.regex.Pattern;
import java.util.zip.*;

public final class HelloIOS {
    public record Greeting(String name, int number) {}
    public static native int nativeAdd(int left, int right);

    private static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }

    private static String describe(Object value) {
        return switch (value) {
            case Greeting(String name, int number) -> name + ":" + number;
            case String text -> "text:" + text;
            case null -> "null";
            default -> "other";
        };
    }


    public static void main(String[] args) throws Exception {
        try {
            for (String key : List.of("os.name", "java.version", "java.vm.name")) {
                String value = System.getProperty(key);
                check(value != null && !value.isBlank(), key);
                System.out.println(key + "=" + value);
            }
            check("iOS".equals(System.getProperty("os.name")), "os.name must be iOS");
            check(System.getProperty("java.version").startsWith("21"), "Java 21 required");
            check(System.getProperty("java.vm.name").contains("OpenJ9"), "OpenJ9 required");
            check(List.of(1, 2, 3, 4).stream().map(x -> x * x).reduce(0, Integer::sum) == 30, "lambda/stream");
            Greeting greeting = new Greeting("iOS", 21);
            check(describe(greeting).equals("iOS:21") && describe("hello").equals("text:hello"), "record/switch pattern");
            check(greeting.getClass().isRecord() && greeting.getClass().getRecordComponents().length == 2, "reflection");
            check(HelloIOS.class.getDeclaredMethod("describe", Object.class).invoke(null, greeting).equals("iOS:21"), "reflective invocation");

            int[] result = {0};
            Thread thread = new Thread(() -> result[0] = 42, "smoke-java-thread");
            thread.start();
            thread.join();
            check(result[0] == 42, "thread/join");
            try (ExecutorService executor = Executors.newFixedThreadPool(2)) {
                check(executor.submit(() -> 6 * 7).get(30, TimeUnit.SECONDS) == 42, "executor");
            }
            check(new BigInteger("12345678901234567890").multiply(BigInteger.TEN).toString().equals("123456789012345678900"), "BigInteger");
            check(new BigDecimal("0.1").add(new BigDecimal("0.2")).compareTo(new BigDecimal("0.3")) == 0, "BigDecimal");
            check(Pattern.compile("(?<word>OpenJ9)-(?<version>\\d+)").matcher("OpenJ9-21").matches(), "regex");
            ZonedDateTime ny = Instant.parse("2024-07-01T12:00:00Z").atZone(ZoneId.of("America/New_York"));
            check(ny.getHour() == 8 && ny.getOffset().equals(ZoneOffset.ofHours(-4)), "timezone database");
            check(DateTimeFormatter.ISO_LOCAL_DATE.format(ny).equals("2024-07-01"), "java.time formatting");
            check(String.format(Locale.GERMANY, "%.2f", 1234.5).equals("1234,50"), "locale formatting");

            String text = "Hello iOS — 日本語 🌍";
            byte[] data = text.getBytes(StandardCharsets.UTF_8);
            check(new String(data, StandardCharsets.UTF_8).equals(text), "UTF-8");
            Path file = Files.createTempFile(Path.of(System.getProperty("java.io.tmpdir")), "openj9-", ".txt");
            try {
                Files.write(file, data);
                check(Files.readString(file).equals(text), "sandbox file IO");
            } finally { Files.deleteIfExists(file); }
            ByteArrayOutputStream zipped = new ByteArrayOutputStream();
            try (ZipOutputStream zip = new ZipOutputStream(zipped)) {
                zip.putNextEntry(new ZipEntry("hello.txt"));
                zip.write(data);
                zip.closeEntry();
            }
            try (ZipInputStream zip = new ZipInputStream(new ByteArrayInputStream(zipped.toByteArray()))) {
                check(zip.getNextEntry().getName().equals("hello.txt"), "zip entry");
                check(Arrays.equals(zip.readAllBytes(), data), "zip round trip");
            }
            ByteArrayOutputStream gzipped = new ByteArrayOutputStream();
            try (GZIPOutputStream gzip = new GZIPOutputStream(gzipped)) { gzip.write(data); }
            try (GZIPInputStream gzip = new GZIPInputStream(new ByteArrayInputStream(gzipped.toByteArray()))) {
                check(Arrays.equals(gzip.readAllBytes(), data), "gzip round trip");
            }
            String digest = HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest("abc".getBytes(StandardCharsets.UTF_8)));
            check(digest.equals("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"), "SHA-256");
            byte[] random = new byte[32];
            new SecureRandom().nextBytes(random);
            check(!Arrays.equals(random, new byte[32]), "SecureRandom");
            try {
                throw new IllegalStateException("expected-smoke-exception");
            } catch (IllegalStateException expected) {
                StringWriter trace = new StringWriter();
                expected.printStackTrace(new PrintWriter(trace));
                check(trace.toString().contains("HelloIOS.main") && trace.toString().contains("expected-smoke-exception"), "exception stack trace");
                System.err.print(trace);
            }
            check(nativeAdd(19, 23) == 42, "RegisterNatives host callback");
            boolean desktopExpected = args.length == 0 || args[0].equals("headless");
            check(ModuleLayer.boot().findModule("java.desktop").isPresent() == desktopExpected,
                  "java.desktop presence does not match the requested runtime variant");
            if (desktopExpected) {
                Class.forName("HeadlessDesktop").getMethod("run").invoke(null);
            } else {
                check(ModuleLayer.boot().findModule("java.datatransfer").isEmpty(), "core runtime includes data transfer");
                for (String name : List.of("java.awt.Font", "javax.imageio.ImageIO", "javax.swing.JButton")) {
                    try {
                        Class.forName(name);
                        throw new AssertionError("core runtime exposed " + name);
                    } catch (ClassNotFoundException expected) {
                        // These APIs must not be available in a core-only runtime.
                    }
                }
                check(Files.notExists(Path.of(System.getProperty("java.home"), "lib", "fonts")),
                      "core runtime contains bundled desktop fonts");
                System.out.println("OPENJ9_IOS_CORE_ONLY_OK");
            }
            Logger.getLogger("HelloIOS").info("java.util.logging smoke passed");
            System.out.println("OPENJ9_IOS_SMOKE_OK");
            System.out.flush();
        } catch (Throwable failure) {
            failure.printStackTrace(System.err);
            System.out.println("OPENJ9_IOS_SMOKE_FAIL: " + failure);
            System.out.flush();
            if (failure instanceof Exception exception) throw exception;
            if (failure instanceof Error error) throw error;
            throw new RuntimeException(failure);
        }
    }
}
