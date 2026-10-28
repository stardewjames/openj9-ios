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
import java.awt.Color;
import java.awt.Font;
import java.awt.Graphics2D;
import java.awt.GraphicsEnvironment;
import java.awt.HeadlessException;
import java.awt.RenderingHints;
import java.awt.font.TextLayout;
import java.awt.image.BufferedImage;
import javax.imageio.ImageIO;

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

    private static void headlessDesktop() throws Exception {
        check(GraphicsEnvironment.isHeadless(), "iOS must use headless AWT");
        try {
            GraphicsEnvironment.getLocalGraphicsEnvironment().getDefaultScreenDevice();
            throw new AssertionError("headless runtime exposed a screen");
        } catch (HeadlessException expected) {
            // Screen operations are unavailable; off-screen rendering must still work.
        }
        BufferedImage image = new BufferedImage(320, 160, BufferedImage.TYPE_INT_ARGB);
        Graphics2D g = image.createGraphics();
        try {
            g.setColor(Color.WHITE);
            g.fillRect(0, 0, 320, 160);
            g.setColor(Color.RED);
            g.fillRect(8, 8, 16, 16);
            g.setRenderingHint(RenderingHints.KEY_TEXT_ANTIALIASING, RenderingHints.VALUE_TEXT_ANTIALIAS_ON);
            int baseline = 42;
            for (String family : List.of("Serif", "SansSerif", "Monospaced", "Dialog", "DialogInput")) {
                Font font = new Font(family, Font.BOLD | Font.ITALIC, 18);
                check(font.canDisplay('A') && font.canDisplay('\u03a9'), family + " font coverage");
                g.setFont(font);
                g.setColor(Color.BLACK);
                TextLayout layout = new TextLayout("OpenJ9 iOS \u03a9", font, g.getFontRenderContext());
                check(layout.getAdvance() > 80 && layout.getAdvance() < 300, family + " text advance");
                layout.draw(g, 32, baseline);
                baseline += 23;
            }
            Font fileFont = Font.createFont(Font.TRUETYPE_FONT,
                Path.of(System.getProperty("java.home"), "lib", "fonts", "DejaVuSans.ttf").toFile());
            check(fileFont.getFamily(Locale.ROOT).equals("DejaVu Sans"), "file-backed font identity");
            g.setClip(250, 8, 10, 10);
            g.setColor(Color.BLUE);
            g.fillRect(240, 0, 40, 40);
        } finally {
            g.dispose();
        }
        check(image.getRGB(12, 12) == Color.RED.getRGB(), "Java2D rectangle");
        check(image.getRGB(252, 12) == Color.BLUE.getRGB()
            && image.getRGB(245, 12) == Color.WHITE.getRGB(), "Java2D clipping");
        boolean ink = false;
        for (int y = 25; y < 145; y++) {
            for (int x = 32; x < 235; x++) ink |= image.getRGB(x, y) != Color.WHITE.getRGB();
        }
        check(ink, "font glyph rasterization produced no ink");
        ByteArrayOutputStream png = new ByteArrayOutputStream();
        check(ImageIO.write(image, "png", png), "PNG encoder unavailable");
        BufferedImage decoded = ImageIO.read(new ByteArrayInputStream(png.toByteArray()));
        check(decoded.getWidth() == 320 && decoded.getHeight() == 160
            && decoded.getRGB(12, 12) == Color.RED.getRGB(), "PNG dimensions/pixel round trip");
        BufferedImage rgb = new BufferedImage(16, 16, BufferedImage.TYPE_INT_RGB);
        Graphics2D jpegGraphics = rgb.createGraphics();
        jpegGraphics.setColor(new Color(48, 96, 144));
        jpegGraphics.fillRect(0, 0, 16, 16);
        jpegGraphics.dispose();
        ByteArrayOutputStream jpeg = new ByteArrayOutputStream();
        check(ImageIO.write(rgb, "jpeg", jpeg), "JPEG encoder unavailable");
        Color sample = new Color(ImageIO.read(new ByteArrayInputStream(jpeg.toByteArray())).getRGB(8, 8));
        check(Math.abs(sample.getRed() - 48) < 8 && Math.abs(sample.getGreen() - 96) < 8
            && Math.abs(sample.getBlue() - 144) < 8, "JPEG colour round trip");
        System.out.println("OPENJ9_IOS_HEADLESS_OK");
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
            headlessDesktop();
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
