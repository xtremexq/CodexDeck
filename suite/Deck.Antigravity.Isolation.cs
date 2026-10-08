using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

// Read-only compatibility check for the Windows amd64 Go CLI. No binary patches
// or authentication data are read. Unknown layouts fail before native launch.
public static class DeckAntigravityIsolation {
    const string Auth = "google3/third_party/jetski/cli/backend/auth/auth.";
    const string Store = "google3/third_party/jetski/language_server/code_assist_client/codeassistclient.";
    sealed class Function { public int Entry, Offset, Length; }
    sealed class Image {
        public byte[] Bytes;
        public int TextRva, TextOffset;
        public List<int[]> Sections = new List<int[]>();
        public Dictionary<string, Function> Functions = new Dictionary<string, Function>();
        public int Raw(int rva) {
            foreach (var s in Sections) if (rva >= s[0] && rva - s[0] < s[2]) return checked(s[1] + rva - s[0]);
            throw new InvalidDataException();
        }
        public bool Calls(string caller, string callee, bool guard) {
            Function a, b;
            if (!Functions.TryGetValue(caller, out a) || !Functions.TryGetValue(callee, out b)) return false;
            for (int i = 0; i + 5 <= a.Length; i++) {
                if (Bytes[a.Offset + i] != 0xe8 || a.Entry + i + 5 + BitConverter.ToInt32(Bytes, a.Offset + i + 1) != b.Entry) continue;
                if (!guard) return true;
                // The static file flag must branch around the keyring path.
                for (int j = i + 5; j < Math.Min(a.Length - 4, i + 16); j++)
                    if (Bytes[a.Offset+j] == 0x84 && Bytes[a.Offset+j+1] == 0xc0 &&
                        (Bytes[a.Offset+j+2] == 0x75 || (Bytes[a.Offset+j+2] == 0x0f && Bytes[a.Offset+j+3] == 0x85))) return true;
            }
            return false;
        }
        public bool Environment(string name, string variable) {
            Function f;
            if (!Functions.TryGetValue(name, out f) || !Calls(name, "os.Getenv", false)) return false;
            var value = Encoding.ASCII.GetBytes(variable);
            for (int i = 0; i + 12 <= f.Length; i++) {
                int p = f.Offset + i;
                // lea rax,[rip+...]; mov ebx,<Go string length>
                if (Bytes[p] != 0x48 || Bytes[p+1] != 0x8d || Bytes[p+2] != 0x05 || Bytes[p+7] != 0xbb || BitConverter.ToInt32(Bytes,p+8) != value.Length) continue;
                int raw = Raw(checked(TextRva + f.Entry + i + 7 + BitConverter.ToInt32(Bytes,p+3)));
                bool equal = true;
                for (int j=0; j<value.Length; j++) if (Bytes[raw+j] != value[j]) { equal=false; break; }
                if (equal) return true;
            }
            return false;
        }
    }
    static Image Read(byte[] bytes, int table) {
        var result = new Image { Bytes=bytes };
        int pe = BitConverter.ToInt32(bytes,0x3c);
        if (BitConverter.ToUInt32(bytes,pe) != 0x4550 || BitConverter.ToUInt16(bytes,pe+4) != 0x8664) throw new InvalidDataException();
        int count=BitConverter.ToUInt16(bytes,pe+6), optional=BitConverter.ToUInt16(bytes,pe+20);
        for (int i=0; i<count; i++) {
            int p=checked(pe+24+optional+40*i);
            int rva=BitConverter.ToInt32(bytes,p+12), size=BitConverter.ToInt32(bytes,p+16), offset=BitConverter.ToInt32(bytes,p+20);
            result.Sections.Add(new[]{rva,offset,size});
            if (Encoding.ASCII.GetString(bytes,p,8).TrimEnd('\0') == ".text") { result.TextRva=rva; result.TextOffset=offset; }
        }
        if (result.TextOffset <= 0 || BitConverter.ToUInt64(bytes,table+24) != 0) throw new InvalidDataException();
        int n=checked((int)BitConverter.ToUInt64(bytes,table+8));
        if (n<=0 || n>1000000) throw new InvalidDataException();
        int names=checked(table+(int)BitConverter.ToUInt64(bytes,table+32));
        int funcs=checked(table+(int)BitConverter.ToUInt64(bytes,table+64));
        for (int i=0; i<n; i++) {
            int p=checked(funcs+8*i), entry=BitConverter.ToInt32(bytes,p), next=BitConverter.ToInt32(bytes,p+8);
            int data=checked(funcs+BitConverter.ToInt32(bytes,p+4));
            int name=checked(names+BitConverter.ToInt32(bytes,data+4));
            int end=name;
            while (end<bytes.Length && end-name<2048 && bytes[end]!=0) end++;
            if (end>=bytes.Length || end-name>=2048 || next<=entry) throw new InvalidDataException();
            string text=Encoding.UTF8.GetString(bytes,name,end-name);
            if (text.StartsWith(Auth,StringComparison.Ordinal) || text.StartsWith(Store,StringComparison.Ordinal) || text == "os.Getenv" || text == "os.UserHomeDir")
                result.Functions[text]=new Function { Entry=entry, Offset=checked(result.TextOffset+entry), Length=next-entry };
        }
        return result;
    }
    public static bool SupportsFileIsolation(string executable) {
        try {
            var bytes=File.ReadAllBytes(executable);
            for (int p=0; p+72<bytes.Length; p++) {
                if (bytes[p]!=0xf1 || bytes[p+1]!=0xff || bytes[p+2]!=0xff || bytes[p+3]!=0xff || bytes[p+4]!=0 || bytes[p+5]!=0 || bytes[p+6]!=1 || bytes[p+7]!=8) continue;
                try {
                    var image=Read(bytes,p);
                    if (!image.Calls(Auth+"NewCLITokenStorage",Store+"NewCompositeTokenStorage",false) ||
                        !image.Calls(Store+"NewCompositeTokenStorage",Store+"shouldBypassKeyring",false) ||
                        !image.Environment(Store+"sshDetector.Detect","SSH_CONNECTION") || !image.Environment("os.UserHomeDir","USERPROFILE")) continue;
                    bool guarded=true;
                    foreach (string operation in new[]{"SaveToken","LoadToken","LoadStoredToken","RemoveToken","SaveUserTier","SaveProjectAndRegion"})
                        if (!image.Calls(Store+"(*compositeTokenStorage)."+operation,Store+"(*compositeTokenStorage).isUseFileStatic",true) ||
                            !image.Functions.ContainsKey(Auth+"(*cliFileTokenStorage)."+operation)) { guarded=false; break; }
                    if (guarded) return true;
                } catch (Exception) { }
            }
        } catch (Exception) { }
        return false;
    }
}
