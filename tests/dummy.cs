using System; using System.IO; using System.Threading; using System.Windows.Forms;
class D { [STAThread] static int Main(string[] a) {
  if (a.Length == 2 && a[0] == "--sleep") { Thread.Sleep(int.Parse(a[1]) * 1000); return 0; }
  string dir = Path.GetDirectoryName(Application.ExecutablePath); string f = Path.Combine(dir, "exit.txt");
  var form = new Form(); form.Text = "Dummy"; int code = 0;
  var t = new System.Windows.Forms.Timer(); t.Interval = 300;
  t.Tick += (s, e) => { if (File.Exists(f)) { code = int.Parse(File.ReadAllText(f).Trim()); File.Delete(f); Application.Exit(); } };
  t.Start(); Application.Run(form); return code; } }
