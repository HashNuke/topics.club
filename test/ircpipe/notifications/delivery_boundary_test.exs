defmodule Ircpipe.Notifications.DeliveryBoundaryTest do
  use Ircpipe.DataCase, async: true

  alias Ircpipe.Notifications.Delivery

  test "invalid receipt checks are ineligible" do
    refute Delivery.eligible?(nil, nil, "not-an-id", nil)
  end

  test "missing notifications are cancelled before delivery" do
    assert {:cancel, :notification_not_found} = Delivery.deliver(-1)
  end
end
