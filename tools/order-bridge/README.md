# Local Codex order screenshot trial

This optional bridge sends an order screenshot from CalorieCapture on iPhone to the authenticated Codex CLI on your Mac. It returns estimated food items to the app's existing review sheet. **An order is not a meal record:** deselect anything you did not eat, edit portions and estimates, then tap Record Intake. Nothing is saved automatically.

## Start on the Mac

1. Install the Codex CLI and run `codex login status`. Sign in if needed. No OpenAI API key is required for the ChatGPT-authenticated CLI path.
2. Connect Mac and iPhone to the same private network. Find the Mac's LAN IPv4 address with `ipconfig getifaddr en0` (or check the active network interface in System Settings).
3. From the repository root, run:

   ```sh
   python3 tools/order-bridge/order_bridge.py --host YOUR_MAC_LAN_IP
   ```

   Keep the terminal running. The bridge prints its HTTPS address, pairing token, and certificate SHA-256 fingerprint. If macOS Firewall prompts, allow incoming connections for Python on the private network.

4. In the iPhone app, open **Settings > Mac Codex**, enter all three values and tap **Save and test connection**. You may need to allow local-network access on the first request.
5. In **Record**, select an order screenshot and tap **Use Mac Codex to recognize order screenshot**. Review the list before recording any item.

The token and private certificate key live under `~/.config/caloriecapture-order-bridge/` on this Mac and are not committed. The iPhone stores the token in Keychain and pins the certificate fingerprint. A new certificate is generated for each Mac IP; if the IP changes, restart with the new IP and update the app settings. The certificate lasts one year. This service listens only on the specified IP and should not be exposed to the public internet. Stop it with Ctrl+C. Screenshots are temporarily written in a private directory and deleted when recognition ends. The Codex CLI is invoked in read-only mode with low reasoning effort and ephemeral session history, but this is still a cloud model request and subject to your Codex usage limits.

The normal DeepSeek photo-recognition button remains available and independent of this trial.
