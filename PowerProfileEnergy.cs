using System;
using System.Collections.Generic;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;

// Optional LAN miIO adapter. No cloud password, power-plan or hibernation calls.
public sealed class ProfilePlugTransport {
    public uint DeviceId {get;private set;}
    static int messageId=new Random().Next(1,9000);
    readonly string address; readonly byte[] token; readonly uint expectedDeviceId;
    public ProfilePlugTransport(string address, string secret):this(address,secret,0){}
    public ProfilePlugTransport(string address, string secret,uint expectedDeviceId) {
        IPAddress ip;
        if(!IPAddress.TryParse(address,out ip) || ip.AddressFamily!=AddressFamily.InterNetwork ||
            !(ip.GetAddressBytes()[0]==10 || (ip.GetAddressBytes()[0]==192 && ip.GetAddressBytes()[1]==168) ||
              (ip.GetAddressBytes()[0]==172 && ip.GetAddressBytes()[1]>=16 && ip.GetAddressBytes()[1]<=31)))
            throw new ArgumentException("请填写插座的局域网 IPv4 地址。");
        if(secret==null || secret.Length!=32)throw new ArgumentException("设备 Token 必须为 32 位十六进制字符。");
        this.address=address;this.expectedDeviceId=expectedDeviceId;token=new byte[16];
        for(int i=0;i<16;i++)token[i]=byte.Parse(secret.Substring(i*2,2),NumberStyles.HexNumber,CultureInfo.InvariantCulture);
    }
    static byte[] Hash(byte[] bytes){using(var h=MD5.Create())return h.ComputeHash(bytes);}
    static byte[] Join(params byte[][] parts){int n=0;foreach(var p in parts)n+=p.Length;var r=new byte[n];n=0;foreach(var p in parts){Buffer.BlockCopy(p,0,r,n,p.Length);n+=p.Length;}return r;}
    static byte[] Slice(byte[] b,int at,int n){var r=new byte[n];Buffer.BlockCopy(b,at,r,0,n);return r;}
    public static byte[] Crypt(byte[] data,byte[] secret,bool encrypt){
        using(var aes=Aes.Create()) {aes.Key=Hash(secret);aes.IV=Hash(Join(aes.Key,secret));aes.Mode=CipherMode.CBC;aes.Padding=PaddingMode.PKCS7;
            using(var transform=encrypt ? aes.CreateEncryptor() : aes.CreateDecryptor())return transform.TransformFinalBlock(data,0,data.Length);}
    }
    public static byte[] Encode(byte[] header,byte[] secret,string json){
        byte[] body=Crypt(Encoding.UTF8.GetBytes(json+"\0"),secret,true);byte[] head=Slice(header,0,16);
        head[0]=0x21;head[1]=0x31;int length=body.Length+32;head[2]=(byte)(length>>8);head[3]=(byte)length;
        return Join(head,Hash(Join(head,secret,body)),body);
    }
    public static string Decode(byte[] packet,byte[] secret){
        if(packet.Length<=32 || packet[0]!=0x21 || packet[1]!=0x31 || ((packet[2]<<8)|packet[3])!=packet.Length)throw new InvalidDataException("设备响应包格式错误。");
        byte[] expected=Hash(Join(Slice(packet,0,16),secret,Slice(packet,32,packet.Length-32)));int diff=0;
        for(int i=0;i<16;i++)diff|=expected[i]^packet[i+16];
        if(diff!=0)throw new InvalidDataException("设备 Token 校验失败，请重新确认授权信息。");
        return Encoding.UTF8.GetString(Crypt(Slice(packet,32,packet.Length-32),secret,false)).TrimEnd('\0');
    }
    public object Call(string method,object[] parameters){
        using(var socket=new UdpClient()){socket.Connect(address,54321);socket.Client.ReceiveTimeout=3000;
            var hello=new byte[32];for(int i=4;i<32;i++)hello[i]=255;hello[0]=0x21;hello[1]=0x31;hello[3]=32;
            socket.Send(hello,hello.Length);var endpoint=new IPEndPoint(IPAddress.Any,0);byte[] response=socket.Receive(ref endpoint);
            if(response.Length!=32 || response[0]!=0x21 || response[1]!=0x31 || response[2]!=0 || response[3]!=32)throw new InvalidDataException("设备未返回有效握手。");
            uint discoveredId=((uint)response[8]<<24)|((uint)response[9]<<16)|((uint)response[10]<<8)|response[11];
            // Check identity before sending authenticated commands to a reused DHCP address.
            if(expectedDeviceId!=0 && discoveredId!=expectedDeviceId)throw new InvalidDataException("插座 IP 已变化：当前地址属于其他设备，请在“连接与电价”更新插座 IP；历史记录已保留。");
            var header=Slice(response,0,16);for(int i=4;i<8;i++)header[i]=0;
            // Match device time, including devices without a correct wall clock.
            for(int i=15;i>=12;i--){if(++header[i]!=0)break;}
            int id=Interlocked.Increment(ref messageId)%9999+1;var json=new JavaScriptSerializer();
            byte[] request=Encode(header,token,json.Serialize(new {id=id,method=method,@params=parameters}));
            socket.Send(request,request.Length);response=socket.Receive(ref endpoint);
            for(int i=8;i<12;i++)if(response.Length<32 || response[i]!=header[i])throw new InvalidDataException("响应设备标识不匹配。");
            var result=json.Deserialize<Dictionary<string,object>>(Decode(response,token));
            if(!result.ContainsKey("id") || Convert.ToInt32(result["id"])!=id)throw new InvalidDataException("设备响应操作标识不匹配。");
            if(result.ContainsKey("error"))throw new InvalidDataException("设备拒绝请求，固件可能不支持本地 MIOT。");
            if(!result.ContainsKey("result"))throw new InvalidDataException("设备响应缺少结果。");
            DeviceId=((uint)header[8]<<24)|((uint)header[9]<<16)|((uint)header[10]<<8)|header[11];return result["result"];
        }
    }
    public void VerifyModel(){
        var info=Call("miIO.info",new object[0]) as Dictionary<string,object>;
        if(info==null || !info.ContainsKey("model") || Convert.ToString(info["model"])!="cuco.plug.v3")
            throw new InvalidDataException("设备型号不匹配；仅允许米家智能插座 3（cuco.plug.v3）。");
    }
    public static Dictionary<string,object> Property(int siid,int piid){return new Dictionary<string,object>{{"did",siid+"-"+piid},{"siid",siid},{"piid",piid}};}
    public static object ReadValue(object result,int siid,int piid){
        var entries=result as System.Collections.IEnumerable;if(entries==null)return null;
        foreach(var entry in entries){var p=entry as Dictionary<string,object>;
            if(p!=null && p.ContainsKey("siid") && p.ContainsKey("piid") && Convert.ToInt32(p["siid"])==siid && Convert.ToInt32(p["piid"])==piid && p.ContainsKey("code") && Convert.ToInt32(p["code"])==0 && p.ContainsKey("value"))return p["value"];}
        return null;
    }
    public object Read(){return Call("get_properties",new object[]{Property(2,1),Property(11,2)});}
    public void Switch(bool on){var p=Property(2,1);p["value"]=on;object result=Call("set_properties",new object[]{p});
        var entries=result as System.Collections.IEnumerable;bool accepted=false;
        if(entries!=null)foreach(var entry in entries){var r=entry as Dictionary<string,object>;if(r!=null && r.ContainsKey("siid") && r.ContainsKey("piid") && Convert.ToInt32(r["siid"])==2 && Convert.ToInt32(r["piid"])==1 && r.ContainsKey("code") && Convert.ToInt32(r["code"])==0)accepted=true;}
        if(!accepted)throw new InvalidDataException("插座未确认开关请求。");}
}

public sealed class ProfileEnergyPoint {public DateTime Time {get;set;} public double Watts {get;set;} public bool BreakBefore {get;set;} public bool InvalidAfter {get;set;} public bool? IsGame {get;set;} }
public sealed class ProfileEnergyDay {public double KWh {get;set;} public double Seconds {get;set;} public string Source {get;set;} public double? HighPowerSeconds {get;set;} public double HighPowerCoverageSeconds {get;set;} public double? GameSeconds {get;set;} public double GameCoverageSeconds {get;set;} public string UsageSource {get;set;} }
public sealed class ProfileCloudHistory {public uint DeviceId {get;set;} public string Model {get;set;} public Dictionary<string,ProfileEnergyDay> Days {get;set;} public string Query {get;set;} public double Multiplier {get;set;} public string FetchedAt {get;set;} }
public sealed class ProfileEnergyHistory {public string Device {get;set;} public List<ProfileEnergyPoint> Points {get;set;} public Dictionary<string,ProfileEnergyDay> Days {get;set;} }
public sealed class ProfileEnergyConfig {public string Address {get;set;} public string Secret {get;set;} public decimal? Price {get;set;} public uint DeviceId {get;set;} }
public sealed class ProfileEnergySnapshot {
    public bool Configured; public bool Busy; public bool? On; public double? Watts; public DateTime ObservedAt;
    public string Status="未连接 · 请设置插座";public decimal? Price;public double? TodayKWh,WeekKWh,MonthKWh;
    public double TodaySeconds,WeekSeconds,MonthSeconds;public string LocalDay,WeekStart,MonthStart;
    public Dictionary<string,ProfileEnergyDay> Days=new Dictionary<string,ProfileEnergyDay>();
    public Dictionary<string,ProfileEnergyDay> UsageDays=new Dictionary<string,ProfileEnergyDay>();
    public DateTime UsageUpdatedAt;
    public List<ProfileEnergyPoint> Points=new List<ProfileEnergyPoint>();
}
public sealed class ProfileEnergyService : IDisposable {
    public const double HighPowerWatts=150;
    readonly object gate=new object();readonly string root;readonly bool autoPoll;System.Threading.Timer timer;bool busy,disposed;
    ProfileEnergyConfig config;ProfileEnergyHistory history;ProfileCloudHistory cloud;ProfileEnergySnapshot snapshot=new ProfileEnergySnapshot();
    readonly Queue<string[]> events=new Queue<string[]>();
    readonly ProfileUsageLogReader usageLogs;ProfileUsageLogCache usageCache;System.Threading.Timer usageTimer;bool usageBusy,usageError;
    static readonly byte[] entropy=Encoding.UTF8.GetBytes("PowerProfile.cuco.plug.v3.v1");
    public ProfileEnergyService(string root):this(root,true){}
    public ProfileEnergyService(string root,bool autoPoll){this.root=root;this.autoPoll=autoPoll;var json=Serializer();
        try {config=json.Deserialize<ProfileEnergyConfig>(ProfileEnergyStore.Read(Path.Combine(root,"energy.settings.json")));}
        catch(FileNotFoundException){config=new ProfileEnergyConfig();}catch{config=new ProfileEnergyConfig();snapshot.Status="连接配置损坏 · 请重新设置";Event("energy.config.failed","连接配置无法读取","WARN");}
        history=new ProfileEnergyHistory{Points=new List<ProfileEnergyPoint>(),Days=new Dictionary<string,ProfileEnergyDay>()};
        try{var loaded=json.Deserialize<ProfileEnergyHistory>(ProfileEnergyStore.Read(Path.Combine(root,"energy.history.json")));if(loaded.Points!=null && loaded.Days!=null && loaded.Device==config.Address)history=loaded;}
        catch(FileNotFoundException){}catch{Event("energy.history.failed","历史记录无法读取；本次重新累计","WARN");snapshot.Status="历史记录损坏 · 重新累计";}
        // Even a short process restart is an unobserved interval.
        if(history.Points.Count>0)history.Points[history.Points.Count-1].InvalidAfter=true;
        snapshot.Configured=!String.IsNullOrWhiteSpace(config.Address) && !String.IsNullOrWhiteSpace(config.Secret);snapshot.Price=config.Price;
        try{cloud=Serializer().Deserialize<ProfileCloudHistory>(ProfileEnergyStore.Read(Path.Combine(root,"energy.cloud.history.json")));ValidateCloud(cloud);}
        catch(FileNotFoundException){}catch{cloud=null;Event("energy.cloud.cache.failed","米家历史缓存无法读取；保留本机估算","WARN");}
        timer=new System.Threading.Timer(_=>Refresh(),null,Timeout.Infinite,Timeout.Infinite);if(snapshot.Configured && autoPoll)timer.Change(0,60000);
        Microsoft.Win32.SystemEvents.PowerModeChanged+=PowerModeChanged;
        usageLogs=new ProfileUsageLogReader(root);usageCache=usageLogs.Cache;
        usageTimer=new System.Threading.Timer(_=>RefreshUsageLogs(),null,autoPoll?0:Timeout.Infinite,autoPoll?60000:Timeout.Infinite);
    }
    public void RefreshUsageLogs(){lock(gate){if(disposed || usageBusy)return;usageBusy=true;}
        try{var loaded=usageLogs.Refresh(DateTime.UtcNow);lock(gate){usageCache=loaded;usageError=false;}}
        catch{lock(gate){if(!usageError)Event("energy.usage.logs.failed","运行日志暂不可读取；保留已有时长统计","WARN");usageError=true;}}
        finally{lock(gate)usageBusy=false;}
    }
    void PowerModeChanged(object sender,Microsoft.Win32.PowerModeChangedEventArgs e){
        if(e.Mode!=Microsoft.Win32.PowerModes.Suspend && e.Mode!=Microsoft.Win32.PowerModes.Resume)return;
        lock(gate){if(disposed)return;if(history.Points.Count>0)history.Points[history.Points.Count-1].InvalidAfter=true;}
        if(e.Mode==Microsoft.Win32.PowerModes.Resume && autoPoll)Refresh();
    }
    static JavaScriptSerializer Serializer(){return new JavaScriptSerializer{MaxJsonLength=4*1024*1024};}
    void Event(string code,string message,string level,string operation=null){lock(gate){if(events.Count>=100)events.Dequeue();events.Enqueue(new[]{code,message,level,operation??Guid.NewGuid().ToString()});}}
    public string[][] DrainEvents(){lock(gate){var r=events.ToArray();events.Clear();return r;}}
    public string Address {get{lock(gate)return config.Address ?? "";}}
    public static void Validate(string address,string secret,decimal? price){if(price.HasValue && (price<0 || price>10))throw new ArgumentException("电价应为 0–10 元/度。");if(!String.IsNullOrWhiteSpace(address))new ProfilePlugTransport(address,secret);}
    public void Configure(string address,string secret,decimal? price){lock(gate){
        if(busy)throw new InvalidOperationException("正在连接或操作插座，请稍后保存。");
        address=address.Trim();string current="";
        if(!String.IsNullOrEmpty(config.Secret))current=Encoding.UTF8.GetString(ProtectedData.Unprotect(Convert.FromBase64String(config.Secret),entropy,DataProtectionScope.CurrentUser));
        bool changedSecret=!String.IsNullOrWhiteSpace(secret) && secret!=current;
        if(String.IsNullOrWhiteSpace(secret))secret=current;Validate(address,secret,price);
        uint deviceId=config.DeviceId;
        bool sameDevice=false;
        if(!String.IsNullOrWhiteSpace(address) && (config.Address!=address || changedSecret) && deviceId!=0){
            var target=new ProfilePlugTransport(address,secret,deviceId);target.VerifyModel();
            if(target.DeviceId!=deviceId)throw new InvalidDataException("新地址属于其他插座；请先核实设备，现有配置与历史记录已保留。");
            sameDevice=true;
        }
        var next=new ProfileEnergyConfig{Address=address,Price=price,DeviceId=String.IsNullOrWhiteSpace(address)?0:deviceId,Secret=String.IsNullOrWhiteSpace(address)?null:Convert.ToBase64String(ProtectedData.Protect(Encoding.UTF8.GetBytes(secret),entropy,DataProtectionScope.CurrentUser))};
        ProfileEnergyStore.Write(Path.Combine(root,"energy.settings.json"),Serializer().Serialize(next));
        if(config.Address!=address || changedSecret){
            if(sameDevice){history.Device=address;if(history.Points.Count>0)history.Points[history.Points.Count-1].InvalidAfter=true;Event("energy.address.updated","新地址经授权与设备 ID 校验通过；已保留该插座的历史用电","INFO");}
            else {history=new ProfileEnergyHistory{Device=address,Points=new List<ProfileEnergyPoint>(),Days=new Dictionary<string,ProfileEnergyDay>()};next.DeviceId=0;}
            ProfileEnergyStore.Write(Path.Combine(root,"energy.history.json"),Serializer().Serialize(history));}
        config=next;snapshot=new ProfileEnergySnapshot{Configured=!String.IsNullOrWhiteSpace(address),Price=price,Status=String.IsNullOrWhiteSpace(address)?"未连接 · 请设置插座":"等待连接"};
        timer.Change(snapshot.Configured && autoPoll?0:Timeout.Infinite,snapshot.Configured && autoPoll?60000:Timeout.Infinite);Event("energy.config.saved","已保存插座配置与固定电价；凭据使用 Windows 当前用户加密","INFO");}}
    public ProfileEnergySnapshot GetSnapshot(){lock(gate){
        var merged=new ProfileEnergyHistory{Days=new Dictionary<string,ProfileEnergyDay>(history.Days)};
        string today=China(DateTime.UtcNow).ToString("yyyy-MM-dd");
        if(cloud!=null && cloud.DeviceId==config.DeviceId && config.DeviceId!=0)foreach(var item in cloud.Days)if(String.CompareOrdinal(item.Key,today)<0)merged.Days[item.Key]=item.Value;
        var r=Summarize(merged,config.Price,DateTime.UtcNow);
        // Cloud energy replaces local kWh, but never replaces locally observed awake time.
        r.UsageDays=Summarize(history,config.Price,DateTime.UtcNow).UsageDays;
        if(usageCache!=null){ProfileUsageLogReader.Merge(r.UsageDays,usageCache);r.UsageUpdatedAt=usageCache.UpdatedAt;}
        r.Configured=snapshot.Configured;r.Busy=busy;r.On=snapshot.On;r.Watts=snapshot.Watts;r.ObservedAt=snapshot.ObservedAt;r.Status=snapshot.Status;r.Points=new List<ProfileEnergyPoint>(history.Points);
        return r;}}
    static void ValidateCloud(ProfileCloudHistory value){
        if(value==null || value.DeviceId==0 || value.Model!="cuco.plug.v3" || value.Days==null || value.Days.Count==0 || value.Days.Count>400)throw new InvalidDataException("历史设备或日期数量无效。");
        foreach(var item in value.Days){DateTime date;var day=item.Value;
            if(!DateTime.TryParseExact(item.Key,"yyyy-MM-dd",CultureInfo.InvariantCulture,DateTimeStyles.None,out date) || date>=China(DateTime.UtcNow).Date || day==null || Double.IsNaN(day.KWh) || Double.IsInfinity(day.KWh) || day.KWh<0 || day.KWh>88.32 || day.Source!="MiHome" || day.Seconds!=0)throw new InvalidDataException("历史日期、单位或电量无效；不会覆盖现有数据。");
        }
    }
    public int ImportCloudHistory(string json){lock(gate){
        var next=Serializer().Deserialize<ProfileCloudHistory>(json);ValidateCloud(next);
        if(config.DeviceId==0 || next.DeviceId!=config.DeviceId)throw new InvalidDataException("历史记录不属于当前已验证的插座。");
        int count=next.Days.Count;
        if(cloud!=null && cloud.DeviceId==next.DeviceId)foreach(var item in cloud.Days)if(!next.Days.ContainsKey(item.Key))next.Days[item.Key]=item.Value;
        string oldest=China(DateTime.UtcNow).AddDays(-400).ToString("yyyy-MM-dd");var remove=new List<string>();foreach(var key in next.Days.Keys)if(String.CompareOrdinal(key,oldest)<0)remove.Add(key);foreach(var key in remove)next.Days.Remove(key);
        ValidateCloud(next);ProfileEnergyStore.Write(Path.Combine(root,"energy.cloud.history.json"),Serializer().Serialize(next));cloud=next;
        Event("energy.cloud.imported","已导入米家完整日统计；同一天优先采用米家历史，不重复计费","INFO");return count;
    }}
    public static ProfileEnergySnapshot Summarize(ProfileEnergyHistory h,decimal? price,DateTime utcNow){
        DateTime today=China(utcNow).Date,week=today.AddDays(-(((int)today.DayOfWeek+6)%7)),month=new DateTime(today.Year,today.Month,1);
        var r=new ProfileEnergySnapshot{Price=price,LocalDay=today.ToString("yyyy-MM-dd"),WeekStart=week.ToString("yyyy-MM-dd"),MonthStart=month.ToString("yyyy-MM-dd")};
        foreach(var item in h.Days){DateTime date;var value=item.Value;
            if(!DateTime.TryParseExact(item.Key,"yyyy-MM-dd",CultureInfo.InvariantCulture,DateTimeStyles.None,out date) || date>today || value==null || Double.IsNaN(value.KWh) || Double.IsInfinity(value.KWh) || value.KWh<0 || Double.IsNaN(value.Seconds) || Double.IsInfinity(value.Seconds) || value.Seconds<0)continue;
            r.Days[item.Key]=new ProfileEnergyDay{KWh=value.KWh,Seconds=value.Seconds,Source=value.Source,HighPowerSeconds=value.HighPowerSeconds,HighPowerCoverageSeconds=value.HighPowerCoverageSeconds,GameSeconds=value.GameSeconds,GameCoverageSeconds=value.GameCoverageSeconds};
            if(value.Source!="MiHome")r.UsageDays[item.Key]=r.Days[item.Key];
            if(date==today){r.TodayKWh=value.KWh;r.TodaySeconds=value.Seconds;}
            if(date>=week){r.WeekKWh=(r.WeekKWh??0)+value.KWh;r.WeekSeconds+=value.Seconds;}
            if(date>=month){r.MonthKWh=(r.MonthKWh??0)+value.KWh;r.MonthSeconds+=value.Seconds;}
        }
        return r;
    }
    public void Refresh(){Start(null);}
    public void SetSwitch(bool on){Start(on);}
    void Start(bool? command){lock(gate){if(disposed || busy || !snapshot.Configured)return;busy=true;snapshot.Busy=true;}
        ThreadPool.QueueUserWorkItem(_=>Collect(command));}
    void Collect(bool? command){string operation=Guid.NewGuid().ToString();try{
        if(command.HasValue)Event("energy.switch.request","已确认手动"+(command.Value?"开启":"关闭")+"插座","INFO",operation);
        ProfileEnergyConfig c;lock(gate)c=config;
        string secret=Encoding.UTF8.GetString(ProtectedData.Unprotect(Convert.FromBase64String(c.Secret),entropy,DataProtectionScope.CurrentUser));
        var transport=new ProfilePlugTransport(c.Address,secret,c.DeviceId);transport.VerifyModel();
        if(c.DeviceId!=0 && transport.DeviceId!=c.DeviceId)throw new InvalidDataException("该 IP 已分配给其他插座，请更新地址；历史记录已保留。");
        if(c.DeviceId==0){lock(gate){c.DeviceId=transport.DeviceId;ProfileEnergyStore.Write(Path.Combine(root,"energy.settings.json"),Serializer().Serialize(c));}}
        if(command.HasValue){transport.Switch(command.Value);Event("energy.switch.accepted","插座确认手动开关请求；正在复核实际状态","INFO",operation);}
        object result=transport.Read();object state=ProfilePlugTransport.ReadValue(result,2,1),power=ProfilePlugTransport.ReadValue(result,11,2);
        if(!(state is bool))throw new InvalidDataException("插座未提供有效开关状态。");
        if(command.HasValue && (bool)state!=command.Value)throw new InvalidDataException("开关读回状态与请求不一致；请在米家核实。");
        if(command.HasValue)Event("energy.switch.confirmed","实际状态已读回：插座"+((bool)state?"已开启":"已关闭"),"INFO",operation);
        double watts;double? validPower=power!=null && double.TryParse(Convert.ToString(power,CultureInfo.InvariantCulture),NumberStyles.Float,CultureInfo.InvariantCulture,out watts) && !double.IsNaN(watts) && !double.IsInfinity(watts) && watts>=0 && watts<=3680 ? watts : (double?)null;
        DateTime now=DateTime.UtcNow;bool? isGame=ReadGameState(root,now);
        lock(gate){if(snapshot.Status!="已连接" && snapshot.Status!="功率读数未提供")Event("energy.connected","插座型号与授权校验通过","INFO",operation);
            snapshot.On=(bool)state;snapshot.Watts=validPower;snapshot.ObservedAt=now;snapshot.Status=validPower.HasValue?"已连接":"功率读数未提供";
            if(validPower.HasValue){history.Device=c.Address;AddSample(history,now,validPower.Value,isGame);}
            ProfileEnergyStore.Write(Path.Combine(root,"energy.history.json"),Serializer().Serialize(history));}
    }catch(Exception ex){lock(gate){string message=ex is SocketException ? "插座无响应 · 检查同一局域网、IP 和固件支持" : ex is CryptographicException ? "设备授权无法解密 · 请重新设置 Token" : ex.Message;
        if(snapshot.Status!=message || command.HasValue)Event(command.HasValue?"energy.switch.failed":"energy.sample.failed",message,"WARN",operation);snapshot.Status=message;
        // Break energy integration across failed reads even if a quick retry succeeds.
        if(history.Points.Count>0)history.Points[history.Points.Count-1].InvalidAfter=true;
    }}finally{lock(gate){busy=false;snapshot.Busy=false;}}}
    static DateTime China(DateTime utc){return TimeZoneInfo.ConvertTimeFromUtc(DateTime.SpecifyKind(utc,DateTimeKind.Utc),TimeZoneInfo.FindSystemTimeZoneById("China Standard Time"));}
    public static bool? ReadGameState(string root,DateTime utcNow){
        try{
            string enabled=Path.Combine(root,"auto_enabled.txt");
            if(File.Exists(enabled) && !String.Equals(ProfileEnergyStore.Read(enabled).Trim(),"true",StringComparison.OrdinalIgnoreCase))return null;
            return ParseGameState(ProfileEnergyStore.Read(Path.Combine(root,"game_detection_state.json")),utcNow);
        }catch{return null;}
    }
    public static bool? ParseGameState(string json,DateTime utcNow){
        try{
            var state=Serializer().Deserialize<Dictionary<string,object>>(json);object stamp,game,source;
            if(state==null || !state.TryGetValue("observedAt",out stamp) || !(stamp is string) || !state.TryGetValue("isGame",out game) || !(game is bool) || !state.TryGetValue("source",out source) || !(source is string) || String.IsNullOrEmpty((string)source))return null;
            DateTimeOffset observed;if(!DateTimeOffset.TryParse((string)stamp,CultureInfo.InvariantCulture,DateTimeStyles.AssumeUniversal,out observed))return null;
            double age=(utcNow-observed.UtcDateTime).TotalSeconds;if(age<0 || age>90)return null;
            if(!(bool)game){switch((string)source){case "NoGameSignal":case "BackgroundInactive":case "WorkstationLocked":case "StartupGuard":return false;default:return null;}}
            switch((string)source){case "ConfiguredGame":case "LibraryGame":case "Foreground3DLoad":case "ConfirmedForeground":case "BackgroundGrace":case "BackgroundGameLoad":return true;default:return null;}
        }catch{return null;}
    }
    public static void AddSample(ProfileEnergyHistory h,DateTime now,double watts){AddSample(h,now,watts,null);}
    public static void AddSample(ProfileEnergyHistory h,DateTime now,double watts,bool? isGame){
        if(double.IsNaN(watts) || double.IsInfinity(watts) || watts<0 || watts>3680)throw new ArgumentOutOfRangeException("watts");
        now=DateTime.SpecifyKind(now,DateTimeKind.Utc);bool gap=true;
        if(h.Points.Count>0){var previous=h.Points[h.Points.Count-1];double seconds=(now-previous.Time).TotalSeconds;
            if(seconds>0 && seconds<=120 && !previous.InvalidAfter){gap=false;DateTime at=previous.Time;
                while(at<now){DateTime local=China(at),boundary=TimeZoneInfo.ConvertTimeToUtc(local.Date.AddDays(1),TimeZoneInfo.FindSystemTimeZoneById("China Standard Time"));DateTime end=boundary<now?boundary:now;
                    double duration=(end-at).TotalSeconds,startW=previous.Watts+(watts-previous.Watts)*(at-previous.Time).TotalSeconds/seconds,endW=previous.Watts+(watts-previous.Watts)*(end-previous.Time).TotalSeconds/seconds;
                    string key=local.ToString("yyyy-MM-dd");if(!h.Days.ContainsKey(key))h.Days[key]=new ProfileEnergyDay();var day=h.Days[key];day.KWh+=(startW+endW)/2*duration/3600000;day.Seconds+=duration;
                    double fraction=startW>=HighPowerWatts && endW>=HighPowerWatts ? 1 : startW<HighPowerWatts && endW<HighPowerWatts ? 0 : (Math.Max(startW,endW)-HighPowerWatts)/Math.Abs(endW-startW);
                    day.HighPowerSeconds=(day.HighPowerSeconds??0)+duration*fraction;day.HighPowerCoverageSeconds+=duration;
                    if(previous.IsGame.HasValue && isGame.HasValue){
                        // Place a binary-state transition midway between observations, then split by day.
                        DateTime transition=previous.Time.AddSeconds(seconds/2);
                        double gameDuration=previous.IsGame==isGame ? (isGame.Value?duration:0) : previous.IsGame.Value ? Math.Max(0,( (end<transition?end:transition)-at).TotalSeconds) : Math.Max(0,(end-(at>transition?at:transition)).TotalSeconds);
                        day.GameSeconds=(day.GameSeconds??0)+gameDuration;day.GameCoverageSeconds+=duration;
                    }
                    at=end;}
            }}
        h.Points.Add(new ProfileEnergyPoint{Time=now,Watts=watts,BreakBefore=gap,IsGame=isGame});h.Points.RemoveAll(p=>p.Time<now.AddDays(-1));
        string oldest=China(now).AddDays(-400).ToString("yyyy-MM-dd");var remove=new List<string>();foreach(var d in h.Days)if(String.CompareOrdinal(d.Key,oldest)<0)remove.Add(d.Key);foreach(var key in remove)h.Days.Remove(key);
    }
    public void Dispose(){lock(gate){disposed=true;timer.Dispose();usageTimer.Dispose();}Microsoft.Win32.SystemEvents.PowerModeChanged-=PowerModeChanged;}
}

public sealed class ProfileEnergyChart : Control {
    public List<ProfileEnergyPoint> Points=new List<ProfileEnergyPoint>();public bool Today;
    readonly ToolTip tip=new ToolTip();string lastTip="";
    public ProfileEnergyChart(){SetStyle(ControlStyles.UserPaint|ControlStyles.AllPaintingInWmPaint|ControlStyles.OptimizedDoubleBuffer,true);BackColor=Color.White;}
    static DateTime Local(DateTime utc){return TimeZoneInfo.ConvertTimeFromUtc(utc,TimeZoneInfo.FindSystemTimeZoneById("China Standard Time"));}
    DateTime Start(DateTime end){return Today ? TimeZoneInfo.ConvertTimeToUtc(Local(end).Date,TimeZoneInfo.FindSystemTimeZoneById("China Standard Time")) : end.AddHours(-1);}
    RectangleF Plot {get{return new RectangleF(44,16,Math.Max(1,Width-64),Math.Max(1,Height-46));}}
    protected override void OnPaint(PaintEventArgs e){
        base.OnPaint(e);var g=e.Graphics;g.SmoothingMode=System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
        var area=Plot;DateTime end=DateTime.UtcNow,start=Start(end);double span=Math.Max(1,(end-start).TotalSeconds);
        var selected=Points.FindAll(p=>p.Time>=start && p.Time<=end);double max=50;foreach(var p in selected)max=Math.Max(max,p.Watts);max=Math.Ceiling(max/50)*50;
        using(var pen=new Pen(Color.FromArgb(233,239,243)))using(var text=new SolidBrush(Color.FromArgb(111,122,132))) {
            for(int i=0;i<=2;i++){float y=area.Bottom-area.Height*i/2;g.DrawLine(pen,area.Left,y,area.Right,y);g.DrawString((max*i/2).ToString("0"),Font,text,3,y-8);}
            g.DrawString("W",Font,text,3,0);
            for(int i=0;i<=3;i++){float x=area.Left+area.Width*i/3;DateTime at=start.AddSeconds(span*i/3);string label=Local(at).ToString("HH:mm");var size=g.MeasureString(label,Font);g.DrawString(label,Font,text,x-size.Width/2,area.Bottom+9);}
            if(selected.Count==0){
                const string empty="暂无有效采样";var size=g.MeasureString(empty,Font);g.DrawString(empty,Font,text,area.Left+(area.Width-size.Width)/2,area.Top+area.Height/2-16);
                const string hint="连接后生成曲线，断线时段留空";size=g.MeasureString(hint,Font);g.DrawString(hint,Font,text,area.Left+(area.Width-size.Width)/2,area.Top+area.Height/2+6);
            }
        }
        using(var pen=new Pen(Color.FromArgb(39,106,159),2))
        using(var fill=new System.Drawing.Drawing2D.LinearGradientBrush(area,Color.FromArgb(55,64,141,183),Color.FromArgb(4,64,141,183),90f))
        using(var dot=new SolidBrush(Color.FromArgb(39,106,159))){
            for(int i=0;i<selected.Count;i++){
                var b=selected[i];float x2=area.Left+(float)((b.Time-start).TotalSeconds/span)*area.Width,y2=area.Bottom-(float)(b.Watts/max)*area.Height;
                bool connected=i>0 && !b.BreakBefore && !selected[i-1].InvalidAfter && (b.Time-selected[i-1].Time).TotalSeconds<=120;
                if(connected){var a=selected[i-1];float x1=area.Left+(float)((a.Time-start).TotalSeconds/span)*area.Width,y1=area.Bottom-(float)(a.Watts/max)*area.Height;
                    g.FillPolygon(fill,new[]{new PointF(x1,area.Bottom),new PointF(x1,y1),new PointF(x2,y2),new PointF(x2,area.Bottom)});g.DrawLine(pen,x1,y1,x2,y2);
                }
                if(!connected || i==selected.Count-1)g.FillEllipse(dot,x2-2.5f,y2-2.5f,5,5);
            }
        }
    }
    protected override void OnMouseMove(MouseEventArgs e){
        base.OnMouseMove(e);DateTime end=DateTime.UtcNow,start=Start(end);var area=Plot;ProfileEnergyPoint nearest=null;double best=10;
        if(area.Contains(e.Location))foreach(var p in Points){if(p.Time<start || p.Time>end)continue;double x=area.Left+(p.Time-start).TotalSeconds/Math.Max(1,(end-start).TotalSeconds)*area.Width,d=Math.Abs(x-e.X);if(d<best){best=d;nearest=p;}}
        string value=nearest==null ? "" : Local(nearest.Time).ToString("HH:mm:ss")+"  ·  "+nearest.Watts.ToString("0.0")+" W（实际采样）";
        if(value!=lastTip){tip.SetToolTip(this,value);lastTip=value;}
    }
    protected override void OnMouseLeave(EventArgs e){base.OnMouseLeave(e);tip.SetToolTip(this,"");lastTip="";}
    protected override void Dispose(bool disposing){if(disposing)tip.Dispose();base.Dispose(disposing);}
}
