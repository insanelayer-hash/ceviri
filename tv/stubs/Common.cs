[assembly: System.Reflection.AssemblyVersion("1.0.0.0")]
namespace Tizen.Applications {
  public class DirectoryInfo {
    public string Data => null; public string Cache => null; public string Resource => null;
    public string SharedData => null; public string SharedResource => null; public string SharedTrusted => null;
  }
  public abstract class Application : System.IDisposable {
    public DirectoryInfo DirectoryInfo => null;
    public string Version => null;
    public virtual void Run(string[] args) {}
    public abstract void Exit();
    public void Dispose() {}
  }
  public class CoreApplication : Application {
    protected virtual void OnCreate() {}
    protected virtual void OnTerminate() {}
    public override void Run(string[] args) {}
    public override void Exit() {}
  }
}
