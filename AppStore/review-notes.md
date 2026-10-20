# App Review Notes - Agora Interactive Podcast 1.0.2 (3)

Agora Interactive Podcast is a podcast-learning app. A listener imports a public episode, connects their own OpenRouter credential, and prepares a full transcript, summary and episode-specific questions. Questions are scheduled after their supporting audio passages. Answers receive a score and constructive feedback.

## Required Review Access

Before submission, provide a working, prefunded regular OpenRouter API key in App Store Connect's confidential review information. Do not put it in source control or this file. Budget-cap the key but allow enough credit to analyze the supplied review episode and grade several answers. Verify this exact key and episode from the submitted TestFlight build.

The current build does not contain an offline sample lesson or an account-free demonstration of live AI. Do not tell reviewers to look for one. Until the dedicated review credential is supplied, review access is not ready.

## Review Steps

1. Open AI Setup using the brain button. Read the disclosure and enable **Allow AI processing**.
2. Select **I Already Have an API Key**, paste the confidential review key, and choose **Verify & Connect**.
3. Leave the recommended analysis quality selected and return to the player.
4. Choose **Import a Podcast** and paste the exact public review-episode URL provided in the confidential review information. Choose **Import, Analyze & Save**.
5. Wait for the cloud job or return to the app later. Long episodes can take several minutes.
6. Play the episode or seek forward to a generated question's time. Enter a response and choose **Submit**. The score and feedback refer to that episode's supported answer.
7. Optional: enable **Complete Hands-Free**, grant microphone and speech recognition permissions, and answer aloud. Narration can be stopped. Say **Repeat the question**, **Start over**, or **Skip this question**.
8. Open Episode Setup and its backlog to submit multiple episodes, retry failed work, or choose a finished episode.
9. AI Setup allows revoking AI-processing permission, disconnecting the provider key and deleting cloud data.

## Data And Costs

AI processing requires explicit permission. The provider key is stored in the device Keychain. Cloud jobs use an encrypted temporary copy, removed on completion, failure or cancellation. Job data expires seven days after creation; scheduled cleanup also removes uncollected results. Answer grading goes directly from the app to OpenRouter. Apple speech recognition can process spoken answers. Provider privacy terms apply separately.

The app has no in-app purchase or Agora subscription. Cloud analysis uses the listener-authorized provider account; a prefunded review credential prevents reviewers from having to buy credits. An optional donation is not required to use any feature.

## Content And Verification

Use a short public episode for which Agora has permission to process the content. Confirm the publisher's terms and include the episode's actual URL in confidential review information. Do not promise support for inaccessible, subscription-only or DRM-protected audio.

Support: https://the-agora-la-app.shareid.chatgpt.site/support

Privacy: https://the-agora-la-app.shareid.chatgpt.site/privacy

Contact: support@theagorala.com
