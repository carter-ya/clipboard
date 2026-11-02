// Independently generate/decode valid images only in the owned Actions temp root.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;

public static class ClipboardValidImageFixtures {
  public static void Write(string root) {
    if (Environment.GetEnvironmentVariable("GITHUB_ACTIONS") != "true" ||
        Environment.OSVersion.Platform != PlatformID.Win32NT)
      throw new InvalidOperationException("valid_image_generator_requires_windows_actions");
    string temp = Path.GetFullPath(Environment.GetEnvironmentVariable("RUNNER_TEMP")).TrimEnd('\\') + "\\";
    root = Path.GetFullPath(root);
    if (!root.StartsWith(temp, StringComparison.OrdinalIgnoreCase) ||
        !Path.GetFileName(root).StartsWith("clipboard-valid-images-", StringComparison.Ordinal) ||
        !Directory.Exists(root))
      throw new InvalidOperationException("valid_image_generator_requires_owned_temp_root");
    foreach (string kind in new string[] { "jpeg", "tiff" }) {
      string path = Path.Combine(root, "fixture." + kind);
      using (var image = new Bitmap(3, 2)) {
        var colors = new Color[] { Color.Red, Color.Lime, Color.Blue, Color.Yellow, Color.Cyan, Color.Magenta };
        for (int index = 0; index < 6; index++) {
          // Uniform JPEG avoids codec-specific chroma rounding. Lossless TIFF
          // independently checks row/channel ordering using distinct colors.
          Color color = kind == "jpeg" ? Color.FromArgb(80, 80, 80) : colors[index];
          image.SetPixel(index % 3, index / 3, color);
        }
        image.Save(path, kind == "jpeg" ? ImageFormat.Jpeg : ImageFormat.Tiff);
      }
      using (var decoded = new Bitmap(path)) {
        if (decoded.Width != 3 || decoded.Height != 2)
          throw new InvalidOperationException("valid_image_fixture_dimensions");
        var pixels = new List<byte>();
        for (int row = 0; row < 2; row++)
          for (int column = 0; column < 3; column++) {
            Color color = decoded.GetPixel(column, row);
            if (color.A != 255) throw new InvalidOperationException("opaque_image_fixture_required");
            pixels.AddRange(new byte[] { color.B, color.G, color.R, color.A });
          }
        File.WriteAllBytes(Path.Combine(root, kind + ".bgra"), pixels.ToArray());
      }
    }
  }
}
