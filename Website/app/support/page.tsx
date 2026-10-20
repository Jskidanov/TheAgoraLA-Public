import type { Metadata } from "next";
import { LegalPage } from "../site-chrome";

export const metadata: Metadata = {
  title: "Listener Support",
  description: "Help importing podcasts and using AI features in The Agora LA.",
};

export default function SupportPage() {
  return (
    <LegalPage
      eyebrow="We are here to help"
      title="Listener Support"
      updated="Guidance for The Agora LA on iPhone"
      asideTitle="Need direct help?"
      asideText="Include the podcast URL, device model, iOS version, and exact error message so the issue can be reproduced quickly."
    >
      <div className="callout">
        <strong>Contact support</strong>
        <br />
        Email{" "}
        <a href="mailto:support@theagorala.com">support@theagorala.com</a>{" "}
        with a short description of what happened.
      </div>

      <h2>Import an episode</h2>
      <p>
        Open Episode Setup and paste an episode or show link from Apple Podcasts,
        Spotify, another major podcast app, a public RSS feed, or a direct HTTPS
        audio link. Choose <strong>Import, Analyze &amp; Save</strong> to replace the
        current episode and prepare everything in one step.
      </p>
      <p>
        An Apple Podcasts episode link imports that episode when Apple includes
        its episode identifier. A show link imports the newest playable episode
        from the publisher&apos;s feed.
      </p>

      <h2>Create the transcript and questions</h2>
      <p>
        Connect an AI provider account you control, choose automatic or manual
        prompt count, then select <strong>Import, Analyze &amp; Save</strong>. Agora
        prefers a complete publisher-provided transcript with audio timestamps.
        When verified timing is unavailable,
        accessible episode audio is transcribed in the secure cloud job using
        your authorized provider.
      </p>
      <p>
        The complete transcript is analyzed before questions are selected. Open
        <strong> View Full Transcript</strong> from the episode screen whenever
        a transcript is available.
      </p>

      <h2>AI access and provider costs</h2>
      <p>
        The Agora is free and does not sell credits. Open <strong>AI Setup</strong>
        and follow the three guided steps:
      </p>
      <ol>
        <li>Read the AI-sharing explanation and enable <strong>Allow AI processing</strong>.</li>
        <li>
          Choose <strong>Connect Automatically</strong>, then sign in or create
          an OpenRouter account and approve The Agora. The secure confirmation
          page returns to the app automatically.
        </li>
        <li>
          Return automatically and choose an analysis quality. Balanced is
          recommended for most listeners.
        </li>
        <li>
          Review the readiness checklist and choose <strong>Return to The Agora</strong>.
        </li>
      </ol>
      <p>
        Already created a key? Return to AI Setup, choose
        <strong> I Already Have an API Key</strong>, select
        <strong> Paste Key from Clipboard</strong>, and then choose
        <strong> Verify &amp; Connect</strong>. The app checks the key before
        saving it in the iPhone Keychain.
      </p>
      <p>
        If the provider reports insufficient credits, choose
        <strong> Open Provider Credits</strong> in the app, manage the provider
        account directly, and retry. The Agora does not receive any payment.
      </p>

      <h2>Disconnect AI</h2>
      <p>
        Open AI Setup and choose <strong>Disconnect AI Account</strong>. This
        removes the provider credential from the iPhone Keychain. The Agora does
        not maintain a separate listener account.
      </p>

      <h2>Manage your data</h2>
      <p>
        AI Setup includes <strong>Delete My Cloud Data</strong> to cancel
        unfinished jobs and remove cloud records. Saved episodes on your phone
        are unchanged. Disable <strong>Allow AI processing</strong> to stop new
        AI requests. Previously prepared episodes can still be played without
        processing a new episode.
      </p>

      <h2>Before contacting support</h2>
      <ul>
        <li>Confirm the podcast page and episode audio are publicly accessible.</li>
        <li>You may leave Agora after it confirms that cloud analysis is running; reopen Episode Setup later to collect the result.</li>
        <li>Try the same episode again after a temporary provider or network error.</li>
        <li>
          Include the podcast URL, device model, iOS version, and exact error
          message when reporting a repeatable issue.
        </li>
      </ul>
    </LegalPage>
  );
}
