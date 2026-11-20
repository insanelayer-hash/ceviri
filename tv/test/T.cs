using System; using System.IO;
class T { static void Main() {
  int w=300,h=40; var px=new byte[w*h]; for(int i=0;i<px.Length;i++) px[i]=(byte)((i%w)*255/w);
  File.WriteAllBytes("/tmp/t.png", TvProbe.Png.Gray(px,w,h));
  string resp="{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"{\\\"en\\\":\\\"LUCIA: Let's go.\\\",\\\"tr\\\":\\\"LUCIA: Hadi gidelim. \\\\u00e7\\\"}\"}],\"role\":\"model\"}}]}";
  string inner=TvProbe.Json.Str(resp,"text"); Console.WriteLine(inner);
  Console.WriteLine(TvProbe.Json.Str(inner,"en")+" | "+TvProbe.Json.Str(inner,"tr"));
  Console.WriteLine(TvProbe.Json.Esc("a\"b\nç"));
}}
