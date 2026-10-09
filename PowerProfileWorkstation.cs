using System;
using System.Runtime.InteropServices;
public static class WorkstationNative {
    [StructLayout(LayoutKind.Sequential)] struct Input { public uint size,time; }
    [StructLayout(LayoutKind.Sequential)] struct Power { public byte ac,battery,percent,reserved;public uint life,fullLife; }
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref Input input);
    [DllImport("kernel32.dll")] static extern uint GetTickCount();
    [DllImport("kernel32.dll")] static extern bool GetSystemPowerStatus(out Power power);
    [DllImport("kernel32.dll")] static extern bool GetSystemTimes(out long idle,out long kernel,out long user);
    public static int IdleSeconds() { Input input=new Input();input.size=(uint)Marshal.SizeOf(input);return GetLastInputInfo(ref input)?(int)((GetTickCount()-input.time)/1000):0; }
    public static bool OnAC() { Power p;return GetSystemPowerStatus(out p)&&p.ac==1; }
    public static long[] Times() { long i,k,u;return GetSystemTimes(out i,out k,out u)?new long[]{i,k,u}:null; }
}
