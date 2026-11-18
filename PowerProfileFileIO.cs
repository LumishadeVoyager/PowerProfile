using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Threading;

// Publish whole snapshots. Never truncate or delete the last committed file.
public static class ProfileSnapshotIO
{
    public static string Read(string path)
    {
        for (int attempt = 0; ; attempt++)
        {
            try
            {
                return ReadCore(path);
            }
            catch (IOException) { if (attempt >= 11) return ReadBetweenWriters(path); Thread.Sleep(40); }
        }
    }

    static string ReadCore(string path)
    {
        using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read,
            FileShare.ReadWrite | FileShare.Delete))
        using (var reader = new StreamReader(stream, Encoding.UTF8, true))
            return reader.ReadToEnd();
    }

    static string ReadBetweenWriters(string path)
    {
        string key;
        using (var hash = SHA256.Create())
            key = BitConverter.ToString(hash.ComputeHash(Encoding.UTF8.GetBytes(Path.GetFullPath(path).ToUpperInvariant()))).Replace("-", "");
        // A rapid sequence of ReplaceFile calls can starve a lock-free reader.
        // Only after short retries, share the writers' mutex to obtain a quiet slot.
        using (var mutex = new Mutex(false, @"Global\PowerProfile_Snapshot_" + key))
        {
            bool held = false;
            try
            {
                try { held = mutex.WaitOne(2000); }
                catch (AbandonedMutexException) { held = true; }
                if (!held) throw new IOException("Snapshot reader timeout: " + path);
                for (int attempt = 0; ; attempt++)
                {
                    try { return ReadCore(path); }
                    catch (IOException) { if (attempt >= 19) throw; Thread.Sleep(40); }
                }
            }
            finally { if (held) mutex.ReleaseMutex(); }
        }
    }

    public static void Write(string path, string json)
    {
        path = Path.GetFullPath(path);
        string key;
        using (var hash = SHA256.Create())
            key = BitConverter.ToString(hash.ComputeHash(Encoding.UTF8.GetBytes(path.ToUpperInvariant()))).Replace("-", "");
        using (var mutex = new Mutex(false, @"Global\PowerProfile_Snapshot_" + key))
        {
            bool held = false;
            string temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try
            {
                try { held = mutex.WaitOne(3000); }
                catch (AbandonedMutexException) { held = true; }
                if (!held) throw new IOException("Snapshot writer timeout: " + path);
                // Persist the complete temporary snapshot before publishing its name.
                using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                {
                    var encoding = new UTF8Encoding(true);
                    byte[] preamble = encoding.GetPreamble();
                    stream.Write(preamble, 0, preamble.Length);
                    byte[] bytes = encoding.GetBytes(json);
                    stream.Write(bytes, 0, bytes.Length);
                    stream.Flush(true);
                }
                for (int attempt = 0; ; attempt++)
                {
                    try
                    {
                        // ReplaceFile supports destination handles opened with FILE_SHARE_DELETE.
                        // All cooperating writers hold this mutex, including initial publication.
                        if (File.Exists(path)) File.Replace(temporary, path, null);
                        else File.Move(temporary, path);
                        break;
                    }
                    catch (IOException exception)
                    {
                        int error = exception.HResult & 0xffff;
                        if (attempt >= 24 || (error != 2 && error != 5 && error != 32 && error != 33 && error != 1175 && error != 1176 && error != 1177))
                            throw new IOException("Snapshot publication failed: " + path + " (Win32 " + error + ")", exception);
                        Thread.Sleep(40);
                    }
                }
            }
            finally
            {
                if (File.Exists(temporary)) File.Delete(temporary);
                if (held) mutex.ReleaseMutex();
            }
        }
    }
}
