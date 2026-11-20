namespace Tizen.Applications {
  public class DirectoryInfoStub { public string Resource => ""; public string Data => ""; }
  public abstract class ServiceApplication {
    public DirectoryInfoStub DirectoryInfo { get; } = new DirectoryInfoStub();
    protected virtual void OnCreate() {} protected virtual void OnTerminate() {}
    public void Run(string[] a) {} }
}
namespace Tizen.System { public static class Information { public static bool TryGetValue<T>(string k, out T v) { v = default; return false; } } }
