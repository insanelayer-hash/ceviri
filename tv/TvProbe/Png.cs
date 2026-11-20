using System;
using System.IO;
using System.IO.Compression;
using System.Text;

namespace TvProbe
{
    // Minimal 8-bit grayscale PNG encoder (enough for sending the subtitle band to the API).
    static class Png
    {
        static readonly uint[] _crc = BuildCrc();

        static uint[] BuildCrc()
        {
            var t = new uint[256];
            for (uint n = 0; n < 256; n++)
            {
                uint c = n;
                for (int k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xEDB88320u ^ (c >> 1) : c >> 1;
                t[n] = c;
            }
            return t;
        }

        static uint Crc(byte[] type, byte[] data)
        {
            uint c = 0xFFFFFFFFu;
            foreach (var b in type) c = _crc[(c ^ b) & 0xFF] ^ (c >> 8);
            foreach (var b in data) c = _crc[(c ^ b) & 0xFF] ^ (c >> 8);
            return c ^ 0xFFFFFFFFu;
        }

        static void BE(Stream s, uint v)
        {
            s.WriteByte((byte)(v >> 24)); s.WriteByte((byte)(v >> 16)); s.WriteByte((byte)(v >> 8)); s.WriteByte((byte)v);
        }

        static void Chunk(Stream s, string type, byte[] data)
        {
            var t = Encoding.ASCII.GetBytes(type);
            BE(s, (uint)data.Length);
            s.Write(t, 0, 4);
            s.Write(data, 0, data.Length);
            BE(s, Crc(t, data));
        }

        public static byte[] Gray(byte[] pixels, int w, int h)
        {
            // Raw scanlines with filter byte 0, zlib-wrapped deflate.
            var raw = new byte[(w + 1) * h];
            for (int y = 0; y < h; y++) Buffer.BlockCopy(pixels, y * w, raw, y * (w + 1) + 1, w);
            byte[] deflated;
            using (var ms = new MemoryStream())
            {
                using (var ds = new DeflateStream(ms, CompressionLevel.Fastest, true)) ds.Write(raw, 0, raw.Length);
                deflated = ms.ToArray();
            }
            uint a = 1, b = 0;
            foreach (var x in raw) { a = (a + x) % 65521; b = (b + a) % 65521; }
            var z = new byte[deflated.Length + 6];
            z[0] = 0x78; z[1] = 0x01;
            Buffer.BlockCopy(deflated, 0, z, 2, deflated.Length);
            uint adler = (b << 16) | a;
            z[z.Length - 4] = (byte)(adler >> 24); z[z.Length - 3] = (byte)(adler >> 16); z[z.Length - 2] = (byte)(adler >> 8); z[z.Length - 1] = (byte)adler;

            using var outp = new MemoryStream();
            outp.Write(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 }, 0, 8);
            var ihdr = new byte[13];
            ihdr[0] = (byte)(w >> 24); ihdr[1] = (byte)(w >> 16); ihdr[2] = (byte)(w >> 8); ihdr[3] = (byte)w;
            ihdr[4] = (byte)(h >> 24); ihdr[5] = (byte)(h >> 16); ihdr[6] = (byte)(h >> 8); ihdr[7] = (byte)h;
            ihdr[8] = 8; ihdr[9] = 0; // 8-bit grayscale
            Chunk(outp, "IHDR", ihdr);
            Chunk(outp, "IDAT", z);
            Chunk(outp, "IEND", new byte[0]);
            return outp.ToArray();
        }
    }
}
