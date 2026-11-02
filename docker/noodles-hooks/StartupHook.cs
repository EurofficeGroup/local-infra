using System;

internal class StartupHook
{
    public static void Initialize()
    {
        Console.WriteLine("local-infra: LocalInfra.NoodlesHooks startup hook loaded");
    }
}
