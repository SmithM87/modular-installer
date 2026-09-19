// Tiny native launcher for Install-Software.ps1.
//
// The script is embedded in this exe as a resource. On start the launcher reads it out and runs it inside an
// in-process Windows PowerShell runspace on an STA thread (WPF requires STA). Built as a Windows (not console)
// app, so double-clicking shows only the installer window. Administrator elevation comes from the exe's
// manifest (see app.manifest), so Windows shows the UAC prompt before anything runs.
//
// Targets the C# 5 compiler that ships with Windows (csc.exe), so no language features newer than that.
using System;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;

[assembly: AssemblyTitle("Modular Installer")]
[assembly: AssemblyDescription("Dark-themed winget installer and system updater")]
[assembly: AssemblyProduct("modular-installer")]
[assembly: AssemblyVersion("1.0.0.0")]

internal static class Launcher
{
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int MessageBoxW(IntPtr hWnd, string text, string caption, uint type);

    private static void ShowError(string message)
    {
        MessageBoxW(IntPtr.Zero, message, "Modular Installer", 0x10 /* MB_ICONERROR */);
    }

    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            string script;
            using (Stream stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("Install-Software.ps1"))
            {
                if (stream == null)
                {
                    ShowError("The embedded installer script is missing. Rebuild with Build-Exe.ps1.");
                    return 2;
                }
                using (StreamReader reader = new StreamReader(stream))
                {
                    script = reader.ReadToEnd();
                }
            }

            using (Runspace runspace = RunspaceFactory.CreateRunspace())
            {
                // Run on this (STA) thread so the WPF window and its dispatcher live on the main thread.
                runspace.ApartmentState = ApartmentState.STA;
                runspace.ThreadOptions = PSThreadOptions.UseCurrentThread;
                runspace.Open();

                using (PowerShell ps = PowerShell.Create())
                {
                    ps.Runspace = runspace;
                    ps.AddScript(script);

                    // Only switch understood: "ModularInstaller.exe -DryRun" simulates winget (no installs).
                    if (Array.Exists(args, delegate(string a) { return string.Equals(a, "-DryRun", StringComparison.OrdinalIgnoreCase); }))
                    {
                        ps.AddParameter("DryRun");
                    }

                    ps.Invoke();
                }
            }
            return 0;
        }
        catch (Exception ex)
        {
            ShowError("The installer failed to start:\n\n" + ex.Message);
            return 1;
        }
    }
}
