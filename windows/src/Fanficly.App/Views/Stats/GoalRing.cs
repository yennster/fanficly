using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;

namespace Fanficly.App.Views.Stats;

/// <summary>
/// A circular progress ring filled clockwise from the top (ReadingGoalRing).
/// Drawn with shapes rather than a determinate <see cref="ProgressRing"/>, whose
/// animated visual the wrap card's image render can't count on capturing.
/// </summary>
public static class GoalRing
{
    public static FrameworkElement Build(double fraction, double size, double thickness, Brush track, Brush fill)
    {
        fraction = Math.Clamp(double.IsNaN(fraction) ? 0 : fraction, 0, 1);
        var host = new Grid { Width = size, Height = size };
        host.Children.Add(new Ellipse { Stroke = track, StrokeThickness = thickness, Margin = new Thickness(thickness / 2) });

        if (fraction >= 1)
        {
            // A full circle: an arc that ends where it starts draws nothing.
            host.Children.Add(new Ellipse { Stroke = fill, StrokeThickness = thickness, Margin = new Thickness(thickness / 2) });
        }
        else if (fraction > 0)
        {
            var center = size / 2;
            var radius = (size - thickness) / 2;
            var angle = fraction * 2 * Math.PI;
            var figure = new PathFigure { StartPoint = new Point(center, center - radius), IsClosed = false, IsFilled = false };
            figure.Segments.Add(new ArcSegment
            {
                Point = new Point(center + radius * Math.Sin(angle), center - radius * Math.Cos(angle)),
                Size = new Size(radius, radius),
                IsLargeArc = fraction > 0.5,
                SweepDirection = SweepDirection.Clockwise,
            });
            var geometry = new PathGeometry();
            geometry.Figures.Add(figure);
            host.Children.Add(new Microsoft.UI.Xaml.Shapes.Path
            {
                Data = geometry,
                Stroke = fill,
                StrokeThickness = thickness,
                StrokeStartLineCap = PenLineCap.Round,
                StrokeEndLineCap = PenLineCap.Round,
            });
        }
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAccessibilityView(host, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        return host;
    }
}
