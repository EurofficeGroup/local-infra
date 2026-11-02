using System;
using System.Linq;
using System.Threading.Tasks;
using NServiceBus;
using NServiceBus.Pipeline;

namespace LocalInfra.NoodlesHooks
{
    public class WindowsDataBusKeyBehavior : Behavior<IIncomingPhysicalMessageContext>
    {
        public const string DataBusHeaderPrefix = "NServiceBus.DataBus.";

        public override Task Invoke(IIncomingPhysicalMessageContext context, Func<Task> next)
        {
            var headers = context.Message.Headers;
            var windowsKeyHeaders = headers
                .Where(h => h.Key.StartsWith(DataBusHeaderPrefix, StringComparison.Ordinal) && h.Value != null && h.Value.Contains('\\'))
                .Select(h => h.Key)
                .ToList();

            foreach (var header in windowsKeyHeaders)
            {
                headers[header] = headers[header].Replace('\\', '/');
            }

            return next();
        }
    }

    public class RegisterWindowsDataBusKeyBehavior : INeedInitialization
    {
        public void Customize(EndpointConfiguration configuration)
        {
            configuration.Pipeline.Register("LocalInfraWindowsDataBusKey", new WindowsDataBusKeyBehavior(),
                "local-infra: replaces '\\' with '/' in data bus keys written by Power on Windows");
            Console.WriteLine("local-infra: WindowsDataBusKeyBehavior registered");
        }
    }
}
