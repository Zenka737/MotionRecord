using System.Windows;

namespace MotionRecord.App;

public partial class App : Application
{
    public App()
    {
        DispatcherUnhandledException += (_, e) =>
        {
            MessageBox.Show(e.Exception.Message, "MotionRecord — ошибка", MessageBoxButton.OK, MessageBoxImage.Error);
            e.Handled = true;
        };
    }
}
