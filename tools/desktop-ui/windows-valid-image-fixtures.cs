// Independently generate/decode valid images only in the owned Actions temp root.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;

public static class ClipboardValidImageFixtures {
  private static byte[] OrientationTiff(int orientation) {
    var tags = new List<uint[]> {
      new uint[] {256,4,1,3}, new uint[] {257,4,1,2}, new uint[] {258,3,3,0},
      new uint[] {259,3,1,1}, new uint[] {262,3,1,2}, new uint[] {273,4,1,0},
      new uint[] {274,3,1,(uint)orientation}, new uint[] {277,3,1,3},
      new uint[] {278,4,1,2}, new uint[] {279,4,1,18}
    };
    uint after = (uint)(8 + 2 + tags.Count * 12 + 4);
    using (var output = new MemoryStream()) {
      using (var writer = new BinaryWriter(output)) {
        writer.Write(new byte[] {73,73,42,0}); writer.Write((uint)8);
        writer.Write((ushort)tags.Count);
        foreach (var tag in tags) {
          writer.Write((ushort)tag[0]); writer.Write((ushort)tag[1]); writer.Write(tag[2]);
          writer.Write(tag[0] == 258 ? after : tag[0] == 273 ? after + 6 : tag[3]);
        }
        writer.Write((uint)0);
        writer.Write((ushort)8); writer.Write((ushort)8); writer.Write((ushort)8);
        writer.Write(new byte[] {255,0,0, 0,255,0, 0,0,255, 255,255,0, 0,255,255, 255,0,255});
        writer.Flush();
        return output.ToArray();
      }
    }
  }
  private static byte[] OrientationJpeg(byte[] original, int orientation) {
    if (original.Length < 2 || original[0] != 255 || original[1] != 216)
      throw new InvalidOperationException("orientation_jpeg_original_signature");
    using (var output = new MemoryStream()) {
      using (var writer = new BinaryWriter(output)) {
        writer.Write(new byte[] {255,216,255,225,0,34,69,120,105,102,0,0,73,73,42,0});
        writer.Write((uint)8); writer.Write((ushort)1);
        writer.Write((ushort)274); writer.Write((ushort)3); writer.Write((uint)1);
        writer.Write((ushort)orientation); writer.Write((ushort)0); writer.Write((uint)0);
        writer.Write(original, 2, original.Length - 2);
        writer.Flush();
        return output.ToArray();
      }
    }
  }

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
      for (int orientation = 1; orientation <= 8; orientation++) {
        string variant = Path.Combine(root, "orientation" + orientation + "." + kind);
        File.WriteAllBytes(variant, kind == "jpeg" ? OrientationJpeg(File.ReadAllBytes(path), orientation) : OrientationTiff(orientation));
        // Independent GDI+ metadata read proves the hand-built orientation
        // fixture is valid before testing the product's separate WIC decoder.
        using (var decoded = new Bitmap(variant)) {
          var property = decoded.GetPropertyItem(0x112);
          if (decoded.Width != 3 || decoded.Height != 2 || property.Type != 3 ||
              property.Value.Length < 2 || BitConverter.ToUInt16(property.Value, 0) != orientation)
            throw new InvalidOperationException("independent_orientation_fixture_metadata");
        }
      }
    }
  }
}
