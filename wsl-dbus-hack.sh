# # -----------------------------------------------------------------------------
# # Workaround for systemd/D-Bus issues in WSL
# # -----------------------------------------------------------------------------
# # Check if we are in a WSL environment with systemd
# if [ -n "$WSL_DISTRO_NAME" ] && [ -e /run/systemd/system ]; then
#   # Check if a D-Bus session is already running for the user
#   if ! pgrep -u "$(id -u)" dbus-daemon > /dev/null; then
#     # Start a new D-Bus session daemon and export its address
#     # The 'eval' is crucial for setting the variables in the current shell
#     if [ -S "$XDG_RUNTIME_DIR/bus" ]; then
#         # Clean up stale socket if it exists
#         rm -f "$XDG_RUNTIME_DIR/bus"
#     fi
#     eval "$(dbus-launch --sh-syntax --exit-with-session)"
#     # The above command will set and export DBUS_SESSION_BUS_ADDRESS and DBUS_SESSION_BUS_PID
#   elif [ -z "$DBUS_SESSION_BUS_ADDRESS" ]; then
#     # If daemon is running but variable is not set, try to find the socket
#     # This is a fallback for reconnecting to an existing session
#     BUS_PID=$(pgrep -u "$(id -u)" dbus-daemon)
#     if [ -n "$BUS_PID" ]; then
#         # Heuristically find the address from the process environment
#         DBUS_ADDRESS=$(grep -z DBUS_SESSION_BUS_ADDRESS "/proc/$BUS_PID/environ" | cut -d= -f2-)
#         if [ -n "$DBUS_ADDRESS" ]; then
#             export DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDRESS"
#         fi
#     fi
#   fi
# fi
# # -----------------------------------------------------------------------------

# UPDATED - using service restart

# -----------------------------------------------------------------------------
# The Correct Kickstart: Restart the systemd user session if it's broken.
# Runs once at login.
# -----------------------------------------------------------------------------

# Check if we're in a systemd-enabled WSL environment.
if [ -n "$WSL_DISTRO_NAME" ] && [ -e /run/systemd/system ]; then

  # Check for the broken state: the systemd-managed D-Bus socket is missing.
  if ! [ -S "/run/user/$(id -u)/bus" ]; then
    echo "Systemd user session is broken. Restarting it..." >&2
    # Use the passwordless sudo permission we just configured.
    sudo /usr/bin/systemctl restart "user@$(id -u).service"
    # The UID is dynamically fetched to make the script portable.
  fi
fi

# Now that the session is fixed, export the correct D-Bus address for this shell.
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
# -----------------------------------------------------------------------------