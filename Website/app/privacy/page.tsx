import type { Metadata } from "next";
import { LegalPage } from "../site-chrome";

export const metadata: Metadata = {
  title: "Privacy Policy",
  description: "How The Agora LA handles podcast and listener information.",
};

export default function PrivacyPage() {
  return (
    <LegalPage
      eyebrow="Your information"
      title="Privacy Policy"
      updated="Effective October 8, 2026"
      asideTitle="The short version"
      asideText="The Agora does not sell personal information or run advertising. Cloud analysis uses an encrypted, short-lived provider credential only for the job you request."
    >
      <h2>What this policy covers</h2>
      <p>
        This policy explains how The Agora LA (&quot;Agora,&quot; &quot;we,&quot;
        &quot;us,&quot; or &quot;our&quot;) handles information when you use The
        Agora LA iOS app.
      </p>

      <h2>Information we handle</h2>
      <ul>
        <li>
          Podcast information you submit, including links, episode audio,
          transcripts, titles, generated summaries and questions, and your
          written or spoken answers.
        </li>
        <li>
          An AI-provider credential created after you authorize a provider
          account. The credential is stored in the iPhone Keychain. When you
          request cloud analysis, an encrypted temporary copy is sent to the
          Agora job service and erased after that job completes or fails.
        </li>
        <li>
          App preferences, saved episode material, generated questions,
          answers, and Agora Points stored locally on your device.
        </li>
      </ul>

      <h2>How we use information</h2>
      <p>
        The app uses this information to import and transcribe episodes, create
        episode-specific learning questions, evaluate your answers, and save
        your learning progress. We do not sell personal information, use it for
        cross-app tracking, or serve advertising.
      </p>

      <h2>AI and service providers</h2>
      <p>
        Before AI processing, AI Setup asks you to explicitly allow sharing
        podcast material, typed or transcribed spoken answers, and narration
        text with OpenRouter and its routed AI providers. Withdraw permission
        in AI Setup to stop new AI requests. Already queued cloud jobs can be
        cancelled or removed with Delete My Cloud Data.
      </p>
      <p>
        When you request cloud episode analysis, the app sends the episode title,
        public audio link or transcript, selected settings, and an encrypted
        temporary provider credential to Agora&apos;s cloud job service. The service
        decrypts the credential only in worker memory, sends the material needed
        for the job to OpenRouter and its routed model provider, then erases the
        credential when the job completes or fails. Answer grading is sent from
        the app to OpenRouter using the provider access you authorized.
      </p>
      <p>
        The Agora does not sell AI credits, collect payments, or receive a share
        of provider charges. You manage any AI-provider account and billing
        relationship separately from the app.
      </p>

      <h2>Retention and deletion</h2>
      <p>
        Saved episodes, transcripts, generated study material, answers, and
        Agora Points remain on your device until you replace them or delete the
        app and its data. Cloud job records, including transcripts and generated
        study material, expire seven days after job creation and are removed by
        scheduled cleanup, even if you never collect the result. A
        pseudonymous installation identifier remains so the app can securely
        retrieve its own jobs. Disconnecting AI removes the Keychain credential.
        OpenRouter and routed model providers may retain information under their
        own policies.
      </p>

      <h2>Security</h2>
      <p>
        Delete My Cloud Data in AI Setup deletes the installation record and
        its cloud jobs, including unfinished work. Saved episodes on your phone
        and your separate provider account are unchanged. Spoken answers use
        Apple speech recognition and go to OpenRouter as text for grading;
        Apple may process speech under its own privacy policy.
      </p>
      <p>
        The app uses encrypted network connections and the iPhone Keychain for
        provider access. No system can guarantee absolute security, but we work
        to limit access and collect only what the product needs.
      </p>

      <h2>Children</h2>
      <p>
        Agora is not directed to children under 13, and we do not knowingly
        collect personal information from children under 13. Podcast content is
        supplied by users and may not be appropriate for every age.
      </p>

      <h2 id="your-choices">Your choices</h2>
      <p>
        You can decline optional microphone and speech-recognition permissions,
        use typed answers instead, disconnect your AI provider, delete saved
        episode data, delete cloud data, withdraw AI-processing permission, or
        delete the app. Provider-account privacy choices must
        be managed with that provider.
      </p>

      <h2>Contact and changes</h2>
      <p>
        For privacy questions or requests, email{" "}
        <a href="mailto:support@theagorala.com">support@theagorala.com</a>.
        We may update this policy as the service changes. The effective date
        above identifies the latest version.
      </p>
    </LegalPage>
  );
}
