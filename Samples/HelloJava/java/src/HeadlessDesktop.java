import java.awt.Color;
import java.awt.Font;
import java.awt.Graphics2D;
import java.awt.GraphicsEnvironment;
import java.awt.HeadlessException;
import java.awt.RenderingHints;
import java.awt.font.TextLayout;
import java.awt.image.BufferedImage;
import java.io.*;
import java.nio.file.Path;
import java.util.List;
import java.util.Locale;
import javax.imageio.ImageIO;

public final class HeadlessDesktop {
    private static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }
    public static void run() throws Exception {
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
}
