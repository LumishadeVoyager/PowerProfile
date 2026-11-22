using System;
using System.Runtime.InteropServices;
// Read-only render endpoint peak meters, including non-default headphones/HDMI outputs.
public static class ProfileMediaAudio {
    [ComImport,Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] public class Enumerator {}
    [ComImport,Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] public interface Devices {
        [PreserveSig] int EnumAudioEndpoints(int flow,uint mask,out Collection devices);
    }
    [ComImport,Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] public interface Collection {
        [PreserveSig] int GetCount(out uint count);
        [PreserveSig] int Item(uint index,out Device device);
    }
    [ComImport,Guid("D666063F-1587-4E43-81F1-B948E807363F"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] public interface Device {
        [PreserveSig] int Activate(ref Guid id,uint context,IntPtr parameters,[MarshalAs(UnmanagedType.IUnknown)]out object value);
    }
    [ComImport,Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] public interface Meter {
        [PreserveSig] int GetPeakValue(out float value);
    }
    static void Release(object value){if(value!=null&&Marshal.IsComObject(value))Marshal.ReleaseComObject(value);}
    // -1 means unavailable, never mistaken for confirmed silence.
    public static float Peak(){object enumerator=null;Collection collection=null;float peak=-1;
        try {
            enumerator=new Enumerator();int result=((Devices)enumerator).EnumAudioEndpoints(0,1,out collection);if(result!=0){return -1;}
            uint count;if(collection.GetCount(out count)!=0)return -1;if(count==0)return 0;
            for(uint i=0;i<count;i++){Device device=null;object meter=null;
                try {if(collection.Item(i,out device)!=0)continue;Guid id=new Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064");if(device.Activate(ref id,23,IntPtr.Zero,out meter)!=0)continue;
                    float value;int status=((Meter)meter).GetPeakValue(out value);if(status==0)peak=Math.Max(peak,value);
                }finally{Release(meter);Release(device);}
            }return peak;
        }catch{return -1;}finally{Release(collection);Release(enumerator);}
    }
}
