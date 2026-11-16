using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Web.Script.Serialization;

public sealed class ProfileGamePowerRange {public DateTime Start,End;public double KWh;}
public sealed class ProfileGameSession {
    public string Id,Name,Source;public DateTime Start,End;public bool Estimated,Open;
    public List<ProfileGamePowerRange> Power=new List<ProfileGamePowerRange>();
    public ProfileGameSession Copy(){var result=(ProfileGameSession)MemberwiseClone();result.Power=Power.Select(p=>new ProfileGamePowerRange{Start=p.Start,End=p.End,KWh=p.KWh}).ToList();return result;}
    public double Seconds {get{return (End-Start).TotalSeconds;}}
    public double SampledSeconds {get{return Power.Sum(p=>(p.End-p.Start).TotalSeconds);}}
    public double? SampledKWh {get{return Power.Count>0?(double?)Power.Sum(p=>p.KWh):null;}}
    public double? AverageWatts {get{return SampledSeconds>0?SampledKWh*3600000/SampledSeconds:null;}}
}
public sealed class ProfileGameSessionCache {public int Version=1;public List<ProfileGameSession> Sessions=new List<ProfileGameSession>();}
public sealed class ProfileGameSessionStore {
    readonly string path;List<ProfileGameSession> sessions=new List<ProfileGameSession>();bool dirty;
    public List<ProfileGameSession> Sessions {get{return sessions;}}
    public ProfileGameSessionStore(string root){path=Path.Combine(root,"games.sessions.history.json");try{var data=Json().Deserialize<ProfileGameSessionCache>(ProfileEnergyStore.Read(path));if(data!=null&&data.Sessions!=null)sessions=data.Sessions.FindAll(Valid);}catch{}}
    static JavaScriptSerializer Json(){return new JavaScriptSerializer{MaxJsonLength=16*1024*1024};}
    static bool Valid(ProfileGameSession s){return s!=null&&!String.IsNullOrWhiteSpace(s.Name)&&s.Name.Length<=200&&s.End>s.Start&&(s.End-s.Start).TotalSeconds<=86400&&s.Power!=null&&s.Power.All(p=>p.End>p.Start&&p.Start>=s.Start&&p.End<=s.End&&!Double.IsNaN(p.KWh)&&!Double.IsInfinity(p.KWh)&&p.KWh>=0&&p.KWh<=100);}
    static ProfileGameSession Make(DateTime start,DateTime end,string name,bool estimated){name=String.IsNullOrWhiteSpace(name)?"未识别游戏":name.Trim();if(name.Length>200)name=name.Substring(0,200);string id;using(var hash=SHA256.Create())id=BitConverter.ToString(hash.ComputeHash(Encoding.UTF8.GetBytes(name.ToLowerInvariant()+"|"+start.Ticks))).Replace("-","").Substring(0,24);return new ProfileGameSession{Id=id,Name=name,Start=start,End=end,Estimated=estimated,Source=estimated?"切档会话推算":"连续游戏识别"};}
    static ProfileGameSession Piece(ProfileGameSession s,DateTime a,DateTime b){var result=Make(a,b,s.Name,s.Estimated);result.Open=s.Open&&b==s.End;result.Power=s.Power.Where(p=>p.Start>=a&&p.End<=b).Select(p=>new ProfileGamePowerRange{Start=p.Start,End=p.End,KWh=p.KWh}).ToList();return result;}
    static List<ProfileGamePowerRange> Pauses(List<ProfileUsagePowerEvent> power,DateTime now){var pauses=new List<ProfileGamePowerRange>();foreach(bool exact in new[]{false,true}){DateTime? down=null;foreach(var e in power.Where(e=>e.Exact==exact&&e.Time<=now).OrderBy(e=>e.Time)){if(!e.Awake){if(!down.HasValue)down=e.Time;}else if(down.HasValue){if(e.Time>down.Value)pauses.Add(new ProfileGamePowerRange{Start=down.Value,End=e.Time});down=null;}}if(down.HasValue)pauses.Add(new ProfileGamePowerRange{Start=down.Value,End=now});}return pauses;}
    public static List<ProfileGameSession> Build(List<ProfileUsageLogPoint> points,List<ProfileUsagePowerEvent> power,DateTime now){
        var pauses=Pauses(power,now);
        var raw=new List<ProfileGameSession>();Action<DateTime,DateTime,string,bool> add=(a,b,name,estimated)=>{if(b<=a)return;var parts=new List<ProfileGamePowerRange>{new ProfileGamePowerRange{Start=a,End=b}};foreach(var pause in pauses){var next=new List<ProfileGamePowerRange>();foreach(var p in parts){if(pause.End<=p.Start||pause.Start>=p.End)next.Add(p);else{if(pause.Start>p.Start)next.Add(new ProfileGamePowerRange{Start=p.Start,End=pause.Start});if(pause.End<p.End)next.Add(new ProfileGamePowerRange{Start=pause.End,End=p.End});}}parts=next;}if(parts.Sum(p=>(p.End-p.Start).TotalSeconds)>86400)return;foreach(var p in parts)raw.Add(Make(p.Start,p.End,name,estimated));};
        ProfileUsageLogPoint mode=null,previous=null,lastObservation=null;string currentName=null;
        foreach(var p in points.Where(p=>p.Time<=now&&p.Time>=now.AddDays(-400)).OrderBy(p=>p.Time)){
            bool supported=mode!=null&&mode.Mode=="Game"&&mode.Game!=false&&(mode.Game==true||!String.IsNullOrEmpty(currentName));
            if(p.Boundary){if(supported)add(mode.Time,p.Time,currentName,true);mode=null;previous=null;currentName=null;lastObservation=null;continue;}
            if(p.Mode!=null){if(supported)add(mode.Time,p.Time,currentName,(p.Time-mode.Time).TotalSeconds>90||mode.Game!=true||p.Game!=true);currentName=p.Game==false?null:p.GameName??(p.Mode=="Game"&&mode!=null&&mode.Mode=="Game"?currentName:null);mode=p;}
            else if(p.Decision&&previous!=null&&previous.Mode==null&&p.Game==true&&previous.Game==true&&(p.Time-previous.Time).TotalSeconds>0&&(p.Time-previous.Time).TotalSeconds<=90)add(previous.Time,p.Time,previous.GameName,false);
            if(p.Decision){previous=p;lastObservation=p;}
        }
        if(mode!=null&&mode.Mode=="Game"&&mode.Game!=false&&(mode.Game==true||!String.IsNullOrEmpty(currentName))&&lastObservation!=null&&lastObservation.Game==true&&lastObservation.Time>mode.Time)add(mode.Time,lastObservation.Time,currentName,true);
        var result=new List<ProfileGameSession>();foreach(var s in raw.OrderBy(s=>s.Start).ThenBy(s=>s.End)){var last=result.Count>0?result[result.Count-1]:null;if(last!=null&&String.Equals(last.Name,s.Name,StringComparison.OrdinalIgnoreCase)&&s.Start<=last.End){last.End=s.End>last.End?s.End:last.End;last.Estimated|=s.Estimated;last.Source=last.Estimated?"切档会话推算":"连续游戏识别";}else result.Add(s);}if(mode!=null&&mode.Mode=="Game"&&result.Count>0&&result[result.Count-1].End==mode.Time&&(now-mode.Time).TotalSeconds<=90)result[result.Count-1].Open=true;return result;
    }
    public void Refresh(List<ProfileUsageLogPoint> points,List<ProfileUsagePowerEvent> power,DateTime now){
        var rebuilt=Build(points,power,now);var merged=sessions.FindAll(s=>s.End>=now.AddDays(-400)&&s.Start<=now);
        foreach(var pause in Pauses(power,now)){var reduced=new List<ProfileGameSession>();foreach(var old in merged){if(old.End<=pause.Start||old.Start>=pause.End)reduced.Add(old);else{if(old.Start<pause.Start)reduced.Add(Piece(old,old.Start,pause.Start));if(old.End>pause.End)reduced.Add(Piece(old,pause.End,old.End));}}merged=reduced;}
        foreach(var fresh in rebuilt){var same=merged.FindAll(s=>String.Equals(s.Name,fresh.Name,StringComparison.OrdinalIgnoreCase)&&s.Start<=fresh.End&&s.End>=fresh.Start);foreach(var old in same){if(old.Start<fresh.Start)fresh.Start=old.Start;if(old.End>fresh.End)fresh.End=old.End;fresh.Estimated|=old.Estimated;fresh.Power.AddRange(old.Power);merged.Remove(old);}var overlaps=merged.FindAll(s=>s.Start<fresh.End&&s.End>fresh.Start);foreach(var old in overlaps){merged.Remove(old);if(old.Start<fresh.Start)merged.Add(Piece(old,old.Start,fresh.Start));if(old.End>fresh.End)merged.Add(Piece(old,fresh.End,old.End));}var normalized=Make(fresh.Start,fresh.End,fresh.Name,fresh.Estimated);normalized.Open=fresh.Open;normalized.Power=fresh.Power.Where(p=>p.Start>=fresh.Start&&p.End<=fresh.End).ToList();merged.Add(normalized);}
        sessions=merged.Where(Valid).OrderBy(s=>s.Start).TakeLastCompat(12000).ToList();dirty=true;
    }
    public void UpdateSamples(List<ProfileEnergyPoint> points){
        var ordered=points.OrderBy(p=>p.Time).ToList();var updated=new List<ProfileGameSession>();foreach(var original in sessions){var s=Piece(original,original.Start,original.End);for(int i=1;i<ordered.Count;i++){var a=ordered[i-1];var b=ordered[i];double total=(b.Time-a.Time).TotalSeconds;if(total<=0||total>120||a.InvalidAfter||b.BreakBefore||Double.IsNaN(a.Watts)||Double.IsNaN(b.Watts)||a.Watts<0||b.Watts<0||a.Watts>3680||b.Watts>3680)continue;DateTime start=a.Time>s.Start?a.Time:s.Start,end=b.Time<s.End?b.Time:s.End;if(end<=start)continue;var pieces=new List<ProfileGamePowerRange>{new ProfileGamePowerRange{Start=start,End=end}};foreach(var old in s.Power){var next=new List<ProfileGamePowerRange>();foreach(var p in pieces){if(old.End<=p.Start||old.Start>=p.End)next.Add(p);else{if(old.Start>p.Start)next.Add(new ProfileGamePowerRange{Start=p.Start,End=old.Start});if(old.End<p.End)next.Add(new ProfileGamePowerRange{Start=old.End,End=p.End});}}pieces=next;}foreach(var p in pieces){double x=a.Watts+(b.Watts-a.Watts)*(p.Start-a.Time).TotalSeconds/total,y=a.Watts+(b.Watts-a.Watts)*(p.End-a.Time).TotalSeconds/total;p.KWh=(x+y)/2*(p.End-p.Start).TotalSeconds/3600000;s.Power.Add(p);dirty=true;}}
            var ranges=new List<ProfileGamePowerRange>();foreach(var p in s.Power.OrderBy(p=>p.Start)){var last=ranges.Count>0?ranges[ranges.Count-1]:null;if(last!=null&&last.End==p.Start&&last.Start.AddHours(8).Date==p.End.AddHours(8).AddTicks(-1).Date){last.End=p.End;last.KWh+=p.KWh;}else if(last==null||last.End<=p.Start)ranges.Add(new ProfileGamePowerRange{Start=p.Start,End=p.End,KWh=p.KWh});}s.Power=ranges;updated.Add(s);}
        sessions=updated;if(dirty){ProfileEnergyStore.Write(path,Json().Serialize(new ProfileGameSessionCache{Sessions=sessions}));dirty=false;}
    }
}
static class ProfileEnumerableCompatibility {public static IEnumerable<T> TakeLastCompat<T>(this IEnumerable<T> values,int count){var list=values.ToList();return list.Skip(Math.Max(0,list.Count-count));}}
