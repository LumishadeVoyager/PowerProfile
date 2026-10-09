using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
public static class ProfileVisual {
    [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr icon);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr window,int command);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window);
    public static void ActivateDashboard(IntPtr window) {
        // STARTUPINFO/SW_HIDE from the hidden PowerShell host can hide the first Form.Show().
        ShowWindow(window,9);
        ShowWindow(window,5);
        SetForegroundWindow(window);
    }
    public static Icon CreateIcon(string mode) {
        Color color=mode=="Game" ? Color.FromArgb(151,75,83) : mode=="Balanced" ? Color.FromArgb(39,106,159) : Color.FromArgb(36,124,112);
        using(Bitmap bitmap=new Bitmap(64,64)) {
            using(Graphics g=Graphics.FromImage(bitmap)) {
                g.SmoothingMode=SmoothingMode.AntiAlias;
                using(Pen pen=new Pen(color,8)) {
                    pen.StartCap=LineCap.Round;pen.EndCap=LineCap.Round;
                    g.DrawArc(pen,10,13,44,43,-48,276);
                    g.DrawLine(pen,32,7,32,30);
                }
            }
            IntPtr handle=bitmap.GetHicon();
            try { return (Icon)Icon.FromHandle(handle).Clone(); }
            finally { DestroyIcon(handle); }
        }
    }
}
public sealed class ProfileToastForm : System.Windows.Forms.Form {
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override System.Windows.Forms.CreateParams CreateParams {
        get { var cp=base.CreateParams;cp.ExStyle|=0x08000000;return cp; }
    }
}
public static class ProfileSystemStatus {
    [DllImport("kernel32.dll")] static extern bool GetSystemTimes(out long idle,out long kernel,out long user);
    [StructLayout(LayoutKind.Sequential)] public class MemoryStatus {
        public uint length=(uint)Marshal.SizeOf(typeof(MemoryStatus)); public uint load;
        public ulong totalPhysical,availablePhysical,totalPage,availablePage,totalVirtual,availableVirtual,extended;
    }
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool GlobalMemoryStatusEx([In,Out] MemoryStatus memory);
    public static double CpuSample(int milliseconds) {
        long i1,k1,u1,i2,k2,u2;
        if(!GetSystemTimes(out i1,out k1,out u1))return -1;
        System.Threading.Thread.Sleep(milliseconds);
        if(!GetSystemTimes(out i2,out k2,out u2))return -1;
        long total=(k2-k1)+(u2-u1); if(total<=0)return -1;
        return Math.Max(0,Math.Min(100,100.0*(total-(i2-i1))/total));
    }
    public static MemoryStatus Memory() { MemoryStatus m=new MemoryStatus(); if(!GlobalMemoryStatusEx(m))return null; return m; }
}
