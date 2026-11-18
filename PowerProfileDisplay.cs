using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Collections.Generic;
using System.Drawing;
using System.Windows.Forms;

// No sleep, hibernate, input injection, display disconnect, or GPU reset APIs.
public sealed class PowerProfileDisplay : IDisposable {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    struct Reason { public uint Version, Flags; public IntPtr Text; }
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr PowerCreateRequest(ref Reason reason);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool PowerSetRequest(IntPtr handle, int type);
    [DllImport("kernel32.dll")] static extern bool PowerClearRequest(IntPtr handle, int type);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr memory);
    [DllImport("powrprof.dll")] static extern uint PowerGetActiveScheme(IntPtr root, out IntPtr scheme);
    [DllImport("powrprof.dll")] static extern uint PowerSetActiveScheme(IntPtr root, ref Guid scheme);
    [DllImport("powrprof.dll")] static extern uint PowerReadACValueIndex(IntPtr root, ref Guid scheme, ref Guid subgroup, ref Guid setting, out uint value);
    [DllImport("powrprof.dll")] static extern uint PowerReadDCValueIndex(IntPtr root, ref Guid scheme, ref Guid subgroup, ref Guid setting, out uint value);
    [DllImport("powrprof.dll")] static extern uint PowerWriteACValueIndex(IntPtr root, ref Guid scheme, ref Guid subgroup, ref Guid setting, uint value);
    [DllImport("powrprof.dll")] static extern uint PowerWriteDCValueIndex(IntPtr root, ref Guid scheme, ref Guid subgroup, ref Guid setting, uint value);
    IntPtr request;
    static void Check(uint code) { if(code!=0) throw new Win32Exception((int)code); }
    public static string Scheme() {
        IntPtr p; Check(PowerGetActiveScheme(IntPtr.Zero,out p));
        try { return ((Guid)Marshal.PtrToStructure(p,typeof(Guid))).ToString(); } finally { LocalFree(p); }
    }
    public static uint Read(string plan,string group,string key,bool dc) {
        Guid p=new Guid(plan),g=new Guid(group),k=new Guid(key);uint value;
        Check(dc?PowerReadDCValueIndex(IntPtr.Zero,ref p,ref g,ref k,out value):PowerReadACValueIndex(IntPtr.Zero,ref p,ref g,ref k,out value));return value;
    }
    public static void Write(string plan,string group,string key,bool dc,uint value) {
        Guid p=new Guid(plan),g=new Guid(group),k=new Guid(key);
        Check(dc?PowerWriteDCValueIndex(IntPtr.Zero,ref p,ref g,ref k,value):PowerWriteACValueIndex(IntPtr.Zero,ref p,ref g,ref k,value));
    }
    public static void Activate(string plan) { Guid p=new Guid(plan);Check(PowerSetActiveScheme(IntPtr.Zero,ref p)); }
    public PowerProfileDisplay() {
        IntPtr text=Marshal.StringToHGlobalUni("PowerProfile 自动熄屏期间保持后台任务运行");
        try { Reason r=new Reason {Version=0,Flags=1,Text=text};request=PowerCreateRequest(ref r); }
        finally { Marshal.FreeHGlobal(text); }
        if(request==IntPtr.Zero || request==new IntPtr(-1)) {request=IntPtr.Zero;throw new Win32Exception(Marshal.GetLastWin32Error());}
        if(!PowerSetRequest(request,1) || !PowerSetRequest(request,3)) {int error=Marshal.GetLastWin32Error();Dispose();throw new Win32Exception(error);}
    }
    // Hardware display-off requests can initiate Modern Standby despite power requests.
    // Cover the displays without invoking the Windows power-transition path.
    sealed class BlackScreen : Form {
        protected override bool ShowWithoutActivation { get { return true; } }
        protected override CreateParams CreateParams { get { var p=base.CreateParams;p.ExStyle|=0x08000080;return p; } }
        public BlackScreen(Rectangle bounds) { FormBorderStyle=FormBorderStyle.None;ShowInTaskbar=false;StartPosition=FormStartPosition.Manual;Bounds=bounds;BackColor=Color.Black;TopMost=true; }
    }
    static readonly List<Form> screens=new List<Form>();
    public static int BlackScreenCount { get { return screens.Count; } }
    public static void ScreensOff() {
        // Rebuild on display attachment, removal, resolution or layout changes.
        Screen[] current=Screen.AllScreens;
        bool same=current.Length==screens.Count;
        if(same)for(int i=0;i<current.Length;i++)if(screens[i].IsDisposed || screens[i].Bounds!=current[i].Bounds){same=false;break;}
        if(!same){
            ScreensOn();
            try { foreach(Screen screen in current) { Form form=new BlackScreen(screen.Bounds);screens.Add(form);form.Show(); } }
            catch { ScreensOn();throw; }
        }
        foreach(Form form in screens){form.TopMost=true;if(!form.Visible)form.Show();}
    }
    public static void ScreensOn() { foreach(Form form in screens){form.Close();form.Dispose();}screens.Clear(); }
    public void Dispose() {
        if(request!=IntPtr.Zero) {PowerClearRequest(request,3);PowerClearRequest(request,1);CloseHandle(request);request=IntPtr.Zero;}
    }
}
