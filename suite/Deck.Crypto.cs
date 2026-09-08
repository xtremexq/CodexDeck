using System;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;

// Windows CNG performs AES-GCM; no custom cryptographic primitive.
public static class DeckCrypto {
    [StructLayout(LayoutKind.Sequential)] struct Auth {
        public int Size, Version; public IntPtr Nonce; public int NonceSize;
        public IntPtr Aad; public int AadSize; public IntPtr Tag; public int TagSize;
        public IntPtr Mac; public int MacSize, AadTotal; public ulong DataTotal; public int Flags;
    }
    [DllImport("bcrypt.dll", CharSet=CharSet.Unicode)] static extern int BCryptOpenAlgorithmProvider(out IntPtr a, string id, string provider, int flags);
    [DllImport("bcrypt.dll", CharSet=CharSet.Unicode)] static extern int BCryptSetProperty(IntPtr a, string name, byte[] data, int size, int flags);
    [DllImport("bcrypt.dll")] static extern int BCryptGenerateSymmetricKey(IntPtr a, out IntPtr k, IntPtr obj, int size, byte[] secret, int secretSize, int flags);
    [DllImport("bcrypt.dll")] static extern int BCryptEncrypt(IntPtr k, byte[] input, int size, ref Auth auth, IntPtr iv, int ivSize, byte[] output, int outputSize, out int result, int flags);
    [DllImport("bcrypt.dll")] static extern int BCryptDecrypt(IntPtr k, byte[] input, int size, ref Auth auth, IntPtr iv, int ivSize, byte[] output, int outputSize, out int result, int flags);
    [DllImport("bcrypt.dll")] static extern int BCryptDestroyKey(IntPtr k);
    [DllImport("bcrypt.dll")] static extern int BCryptCloseAlgorithmProvider(IntPtr a, int flags);
    [DllImport("bcrypt.dll")] static extern int BCryptDeriveKeyPBKDF2(IntPtr a, byte[] password, int passwordSize, byte[] salt, int saltSize, ulong iterations, byte[] output, int outputSize, int flags);
    static void Check(int status) { if(status != 0) throw new CryptographicException("Backup authentication or encryption failed."); }
    public static byte[] Random(int size) { var b=new byte[size]; using(var rng=RandomNumberGenerator.Create()) rng.GetBytes(b); return b; }
    public static byte[] Derive(byte[] password, byte[] salt) {
        IntPtr algorithm=IntPtr.Zero; var key=new byte[32]; bool success=false;
        try {
            Check(BCryptOpenAlgorithmProvider(out algorithm,"SHA256",null,8));
            Check(BCryptDeriveKeyPBKDF2(algorithm,password,password.Length,salt,salt.Length,600000,key,key.Length,0));
            success=true; return key;
        } finally {
            if(!success) Array.Clear(key,0,key.Length);
            if(algorithm!=IntPtr.Zero) BCryptCloseAlgorithmProvider(algorithm,0);
        }
    }
    public static byte[] Transform(bool encrypt, byte[] key, byte[] nonce, byte[] input, byte[] tag, byte[] aad) {
        if(key.Length!=32 || nonce.Length!=12 || tag.Length!=16) throw new ArgumentException("Invalid AES-GCM parameters.");
        IntPtr algorithm=IntPtr.Zero, handle=IntPtr.Zero;
        var n=GCHandle.Alloc(nonce,GCHandleType.Pinned); var t=GCHandle.Alloc(tag,GCHandleType.Pinned); var ad=GCHandle.Alloc(aad,GCHandleType.Pinned);
        var output=new byte[input.Length]; bool success=false;
        try {
            Check(BCryptOpenAlgorithmProvider(out algorithm,"AES",null,0));
            var mode=Encoding.Unicode.GetBytes("ChainingModeGCM\0");
            Check(BCryptSetProperty(algorithm,"ChainingMode",mode,mode.Length,0));
            Check(BCryptGenerateSymmetricKey(algorithm,out handle,IntPtr.Zero,0,key,key.Length,0));
            var auth=new Auth { Size=Marshal.SizeOf(typeof(Auth)),Version=1,Nonce=n.AddrOfPinnedObject(),NonceSize=nonce.Length,Tag=t.AddrOfPinnedObject(),TagSize=tag.Length,Aad=ad.AddrOfPinnedObject(),AadSize=aad.Length };
            int count;
            Check(encrypt ? BCryptEncrypt(handle,input,input.Length,ref auth,IntPtr.Zero,0,output,output.Length,out count,0) : BCryptDecrypt(handle,input,input.Length,ref auth,IntPtr.Zero,0,output,output.Length,out count,0));
            if(count!=input.Length) throw new CryptographicException("Invalid backup size.");
            success=true; return output;
        } finally {
            if(!success) Array.Clear(output,0,output.Length);
            if(handle!=IntPtr.Zero) BCryptDestroyKey(handle);
            if(algorithm!=IntPtr.Zero) BCryptCloseAlgorithmProvider(algorithm,0);
            n.Free(); t.Free(); ad.Free();
        }
    }
}
