using System;
using System.Collections.Generic;
using System.Diagnostics.Eventing.Reader;
using System.Globalization;
using System.IO;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

public sealed class ProfileUsageLogPoint {public DateTime Time;public bool? Game;public bool Decision;public bool Boundary;}
public sealed class ProfileUsageLogCache {
    public DateTime UpdatedAt {get;set;}
    public bool SleepBoundariesAvailable {get;set;}
    public Dictionary<string,ProfileEnergyDay> Days {get;set;}
}
public sealed class ProfileUsageLogReader {
    readonly string root;readonly bool readSleepEvents;string fingerprint="";
    ProfileUsageLogCache cache;
    static readonly TimeZoneInfo ChinaZone=TimeZoneInfo.FindSystemTimeZoneById("China Standard Time");
    public ProfileUsageLogReader(string root):this(root,true){}
    public ProfileUsageLogReader(string root,bool readSleepEvents){this.root=root;this.readSleepEvents=readSleepEvents;
        try{cache=new JavaScriptSerializer{MaxJsonLength=4*1024*1024}.Deserialize<ProfileUsageLogCache>(ProfileEnergyStore.Read(Path.Combine(root,"usage.logs.history.json")));Validate(cache);}
        catch{cache=new ProfileUsageLogCache{Days=new Dictionary<string,ProfileEnergyDay>()};}
    }
    public ProfileUsageLogCache Cache {get{return cache;}}
    static void Validate(ProfileUsageLogCache value){
        if(value==null || value.Days==null || value.Days.Count>401)throw new InvalidDataException();
        foreach(var entry in value.Days){DateTime date;var d=entry.Value;
            if(!DateTime.TryParseExact(entry.Key,"yyyy-MM-dd",CultureInfo.InvariantCulture,DateTimeStyles.None,out date) || d==null || !Finite(d.Seconds) || d.Seconds<0 || d.Seconds>86400 || !Finite(d.GameCoverageSeconds) || d.GameCoverageSeconds<0 || d.GameCoverageSeconds>d.Seconds+0.01 || (d.GameSeconds.HasValue && (!Finite(d.GameSeconds.Value) || d.GameSeconds<0 || d.GameSeconds>d.GameCoverageSeconds+0.01)))throw new InvalidDataException();
        }
    }
    static bool Finite(double n){return !Double.IsNaN(n) && !Double.IsInfinity(n);}
    public static bool? GameSignal(string source){
        switch(source){case "ConfiguredGame":case "LibraryGame":case "Foreground3DLoad":case "ConfirmedForeground":case "BackgroundGrace":case "BackgroundGameLoad":return true;
        case "NoGameSignal":case "BackgroundInactive":case "WorkstationLocked":case "StartupGuard":return false;default:return null;}
    }
    static bool? LegacySignal(string message){
        foreach(string source in new[]{"ConfiguredGame","LibraryGame","Foreground3DLoad","ConfirmedForeground","BackgroundGrace","BackgroundGameLoad"})if(message.StartsWith(source+" ",StringComparison.Ordinal) || message==source)return true;
        if(message.StartsWith("无已确认游戏",StringComparison.Ordinal) || message.StartsWith("锁屏/",StringComparison.Ordinal) || message.StartsWith("后台游戏已低负载",StringComparison.Ordinal))return false;
        return null; // A manually selected Game profile is not evidence of a game.
    }
    static IEnumerable<string> Lines(string path){
        using(var stream=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete))
        using(var reader=new StreamReader(stream)){string line;while((line=reader.ReadLine())!=null)yield return line;}
    }
    public static ProfileUsageLogPoint ParseRecord(string line){
        try{
            var json=new JavaScriptSerializer{MaxJsonLength=512*1024};var record=json.Deserialize<Dictionary<string,object>>(line);
            object stamp,eventName,dataObject,message;DateTimeOffset time;
            if(record==null || !record.TryGetValue("timestamp",out stamp) || !DateTimeOffset.TryParse(Convert.ToString(stamp),CultureInfo.InvariantCulture,DateTimeStyles.AssumeUniversal,out time) || !record.TryGetValue("event",out eventName))return null;
            record.TryGetValue("data",out dataObject);record.TryGetValue("message",out message);var data=dataObject as Dictionary<string,object>;
            string code=Convert.ToString(eventName);var point=new ProfileUsageLogPoint{Time=time.UtcDateTime};
            if(code=="tray.switch" || (code=="tray.lifecycle" && (Convert.ToString(message).Contains("[START]") || Convert.ToString(message).Contains("[EXIT]")))){point.Boundary=true;return point;}
            if(code=="auto.decision"){
                object source;point.Decision=true;point.Game=data!=null && data.TryGetValue("source",out source)?GameSignal(Convert.ToString(source)):null;return point;
            }
            if(code=="worker.request" || code=="workstation.decision")return point;
            if(code=="profile.apply.success"){point.Decision=true;point.Game=LegacySignal(Convert.ToString(message));return point;}
        }catch{}
        return null;
    }
    public static ProfileUsageLogPoint ParseLegacy(string line){
        try{
            DateTime local;if(line.Length<32 || !DateTime.TryParseExact(line.Substring(0,19),"yyyy-MM-dd HH:mm:ss",CultureInfo.InvariantCulture,DateTimeStyles.None,out local) || !line.Substring(19).TrimStart().StartsWith("switched to ",StringComparison.Ordinal))return null;
            int at=line.IndexOf("Reason: ",StringComparison.Ordinal);
            return new ProfileUsageLogPoint{Time=TimeZoneInfo.ConvertTimeToUtc(DateTime.SpecifyKind(local,DateTimeKind.Unspecified),ChinaZone),Decision=true,Game=at<0?null:LegacySignal(line.Substring(at+8))};
        }catch{return null;}
    }
    sealed class Range {public DateTime Start,End;}
    static double Duration(List<Range> ranges){
        ranges.Sort((a,b)=>a.Start.CompareTo(b.Start));DateTime? start=null;DateTime end=DateTime.MinValue;double total=0;
        foreach(var range in ranges){if(!start.HasValue){start=range.Start;end=range.End;}else if(range.Start<=end){if(range.End>end)end=range.End;}else{total+=(end-start.Value).TotalSeconds;start=range.Start;end=range.End;}}
        return total+(start.HasValue?(end-start.Value).TotalSeconds:0);
    }
    static void Add(Dictionary<string,List<Range>> days,DateTime start,DateTime end){
        while(start<end){DateTime local=TimeZoneInfo.ConvertTimeFromUtc(start,ChinaZone);DateTime midnight=TimeZoneInfo.ConvertTimeToUtc(local.Date.AddDays(1),ChinaZone);DateTime until=end<midnight?end:midnight;string key=local.ToString("yyyy-MM-dd");
            if(!days.ContainsKey(key))days[key]=new List<Range>();days[key].Add(new Range{Start=start,End=until});start=until;}
    }
    static bool Crosses(List<DateTime> boundaries,DateTime start,DateTime end){int index=boundaries.BinarySearch(start);index=index<0?~index:index+1;return index<boundaries.Count && boundaries[index]<=end;}
    public static Dictionary<string,ProfileEnergyDay> Build(List<ProfileUsageLogPoint> points,List<DateTime> boundaries,DateTime utcNow){
        var valid=points.FindAll(p=>p.Time<=utcNow && p.Time>=utcNow.AddDays(-400));valid.Sort((a,b)=>a.Time.CompareTo(b.Time));
        boundaries=new List<DateTime>(boundaries);foreach(var p in valid)if(p.Boundary)boundaries.Add(p.Time);boundaries.Sort();
        var awake=new Dictionary<string,List<Range>>();var coverage=new Dictionary<string,List<Range>>();var games=new Dictionary<string,List<Range>>();
        ProfileUsageLogPoint previous=null,decision=null;
        foreach(var point in valid){
            if(point.Boundary){previous=null;decision=null;continue;}
            if(previous!=null){double seconds=(point.Time-previous.Time).TotalSeconds;if(seconds>0 && seconds<=90 && !Crosses(boundaries,previous.Time,point.Time))Add(awake,previous.Time,point.Time);}
            previous=point;
            if(!point.Decision)continue;
            if(decision!=null){double seconds=(point.Time-decision.Time).TotalSeconds;
                if(seconds>0 && seconds<=90 && decision.Game.HasValue && point.Game.HasValue && !Crosses(boundaries,decision.Time,point.Time)){
                    Add(coverage,decision.Time,point.Time);
                    if(decision.Game==point.Game){if(point.Game.Value)Add(games,decision.Time,point.Time);}
                    else {DateTime middle=decision.Time.AddSeconds(seconds/2);Add(games,decision.Game.Value?decision.Time:middle,decision.Game.Value?middle:point.Time);}
                }}
            decision=point;
        }
        var result=new Dictionary<string,ProfileEnergyDay>();
        foreach(var pair in awake){double known=coverage.ContainsKey(pair.Key)?Duration(coverage[pair.Key]):0;result[pair.Key]=new ProfileEnergyDay{Seconds=Duration(pair.Value),Source="Logs",GameCoverageSeconds=known,GameSeconds=known>0?(games.ContainsKey(pair.Key)?Duration(games[pair.Key]):0):(double?)null};}
        return result;
    }
    static List<DateTime> SleepBoundaries(out bool available){
        var result=new List<DateTime>();available=false;
        try{
            string xpath="*[System[Provider[@Name='Microsoft-Windows-Kernel-Power'] and (EventID=42 or EventID=107 or EventID=506 or EventID=507) and TimeCreated[timediff(@SystemTime) <= 34560000000]]]";
            var query=new EventLogQuery("System",PathType.LogName,xpath){ReverseDirection=true};
            using(var reader=new EventLogReader(query)){for(int i=0;i<4096;i++){using(var entry=reader.ReadEvent()){if(entry==null)break;if(entry.TimeCreated.HasValue)result.Add(entry.TimeCreated.Value.ToUniversalTime());}}}available=true;
        }catch{}
        return result;
    }
    public ProfileUsageLogCache Refresh(DateTime utcNow){
        var files=new List<string>();string directory=Path.Combine(root,"logs");
        if(Directory.Exists(directory))foreach(var path in Directory.GetFiles(directory,"PowerProfile-*.jsonl*"))if(Regex.IsMatch(Path.GetFileName(path),@"^PowerProfile-\d{4}-\d{2}-\d{2}\.jsonl(?:\.[123])?$"))files.Add(path);
        string legacy=Path.Combine(root,"profile.log");if(File.Exists(legacy))files.Add(legacy);
        if(files.Count==0)return cache;
        files.Sort(StringComparer.Ordinal);var parts=new List<string>();foreach(var path in files){var f=new FileInfo(path);parts.Add(path+":"+f.Length+":"+f.LastWriteTimeUtc.Ticks);}
        string next=String.Join("|",parts.ToArray());if(next==fingerprint)return cache;
        var points=new List<ProfileUsageLogPoint>();
        foreach(var file in files)foreach(var line in Lines(file)){if(line.Length>512*1024)continue;var p=file==legacy?ParseLegacy(line):ParseRecord(line);if(p!=null)points.Add(p);}
        bool sleepAvailable=false;var boundaries=readSleepEvents?SleepBoundaries(out sleepAvailable):new List<DateTime>();var days=Build(points,boundaries,utcNow);
        var merged=new Dictionary<string,ProfileEnergyDay>(cache.Days);string oldest=TimeZoneInfo.ConvertTimeFromUtc(utcNow,ChinaZone).AddDays(-400).ToString("yyyy-MM-dd");
        foreach(var pair in days){ProfileEnergyDay old;if(!merged.TryGetValue(pair.Key,out old) || pair.Value.Seconds>=old.Seconds)merged[pair.Key]=pair.Value;}
        var remove=new List<string>();foreach(var key in merged.Keys)if(String.CompareOrdinal(key,oldest)<0)remove.Add(key);foreach(var key in remove)merged.Remove(key);
        var updated=new ProfileUsageLogCache{Days=merged,UpdatedAt=utcNow,SleepBoundariesAvailable=sleepAvailable};Validate(updated);
        ProfileEnergyStore.Write(Path.Combine(root,"usage.logs.history.json"),new JavaScriptSerializer{MaxJsonLength=4*1024*1024}.Serialize(updated));cache=updated;fingerprint=next;return cache;
    }
    public static void Merge(Dictionary<string,ProfileEnergyDay> usage,ProfileUsageLogCache logs){
        foreach(var pair in logs.Days){ProfileEnergyDay day;
            if(!usage.TryGetValue(pair.Key,out day)){day=new ProfileEnergyDay();usage[pair.Key]=day;}
            // Older power summaries have no interval positions. Use the larger observed
            // coverage as a conservative lower bound instead of adding overlapping totals.
            day.Seconds=Math.Max(day.Seconds,pair.Value.Seconds);
            day.GameCoverageSeconds=Math.Max(day.GameCoverageSeconds,pair.Value.GameCoverageSeconds);
            if(pair.Value.GameSeconds.HasValue)day.GameSeconds=Math.Max(day.GameSeconds??0,pair.Value.GameSeconds.Value);
            day.UsageSource="日志 / 采样估算";
        }
    }
}
