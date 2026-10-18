using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;

namespace Fanficly.App.Views.Reader;

/// <summary>
/// A Grid that shows up in UI Automation as a named group (plain panels have no
/// automation peer, so their AutomationId would be invisible to Narrator and to
/// the UI tests). The reader's regions — its root, the reading area, each page,
/// the page footer and the narration bar — are built from it.
/// </summary>
internal sealed partial class RegionGrid : Grid
{
    public RegionGrid(string? automationId = null, string? name = null)
    {
        if (automationId is not null) AutomationProperties.SetAutomationId(this, automationId);
        if (name is not null) AutomationProperties.SetName(this, name);
    }

    protected override AutomationPeer OnCreateAutomationPeer() => new RegionPeer(this);
}

internal sealed partial class RegionPeer(FrameworkElement owner) : FrameworkElementAutomationPeer(owner)
{
    protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Group;

    protected override string GetClassNameCore() => "ReaderRegion";

    protected override bool IsControlElementCore() => true;
}
