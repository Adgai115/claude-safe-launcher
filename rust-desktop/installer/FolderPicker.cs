using System;
using System.IO;
using System.Runtime.InteropServices;

internal static class FolderPicker
{
    private const uint PickFolders = 0x00000020;
    private const uint ForceFileSystem = 0x00000040;
    private const uint NoChangeDirectory = 0x00000008;
    private const uint PathMustExist = 0x00000800;
    private const uint FileSystemPath = 0x80058000;
    private const int Cancelled = unchecked((int)0x800704C7);

    public static string Select(IntPtr owner, string start)
    {
        var dialog = (IFileDialog)Activator.CreateInstance(
            Type.GetTypeFromCLSID(new Guid("DC1C5A9C-E88A-4DDE-A5A1-60F82A20AEF7")));
        try
        {
            dialog.SetTitle("选择安装文件夹");
            dialog.SetOkButtonLabel("选择此文件夹");
            dialog.SetOptions(PickFolders | ForceFileSystem | NoChangeDirectory | PathMustExist);
            if (start != null)
            {
                var folder = Directory.Exists(start) ? start : Path.GetDirectoryName(start);
                IShellItem location;
                var iid = typeof(IShellItem).GUID;
                if (Directory.Exists(folder) && SHCreateItemFromParsingName(folder, IntPtr.Zero, ref iid, out location) >= 0)
                {
                    try { dialog.SetFolder(location); }
                    finally { Marshal.ReleaseComObject(location); }
                }
            }
            int result = dialog.Show(owner);
            if (result == Cancelled) return null;
            Marshal.ThrowExceptionForHR(result);
            IShellItem selected;
            dialog.GetResult(out selected);
            try
            {
                IntPtr path;
                selected.GetDisplayName(FileSystemPath, out path);
                try { return Marshal.PtrToStringUni(path); }
                finally { Marshal.FreeCoTaskMem(path); }
            }
            finally { Marshal.ReleaseComObject(selected); }
        }
        finally { Marshal.ReleaseComObject(dialog); }
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int SHCreateItemFromParsingName(string path, IntPtr context, ref Guid iid, out IShellItem item);

    [ComImport, Guid("42F85136-DB7E-439C-85F1-E4075D135FC8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IFileDialog
    {
        [PreserveSig] int Show(IntPtr owner);
        void SetFileTypes(uint count, IntPtr types);
        void SetFileTypeIndex(uint index);
        void GetFileTypeIndex(out uint index);
        void Advise(IntPtr events, out uint cookie);
        void Unadvise(uint cookie);
        void SetOptions(uint options);
        void GetOptions(out uint options);
        void SetDefaultFolder(IShellItem item);
        void SetFolder(IShellItem item);
        void GetFolder(out IShellItem item);
        void GetCurrentSelection(out IShellItem item);
        void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string name);
        void GetFileName(out IntPtr name);
        void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string title);
        void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string title);
        void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string title);
        void GetResult(out IShellItem item);
    }

    [ComImport, Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellItem
    {
        void BindToHandler(IntPtr context, ref Guid handler, ref Guid iid, out IntPtr result);
        void GetParent(out IShellItem parent);
        void GetDisplayName(uint format, out IntPtr name);
    }
}
