# iOS Agent Capabilities

An iOS app can provide an AI agent with tools for supported system services and connected accounts. Each integration needs its own implementation and appropriate user authorization.

Email is possible. Messages and Apple Notes have tighter limits.

## Email, Messages and Notes

| Integration | What an iOS agent could do |
| --- | --- |
| **Gmail / Outlook** | Read, search, summarize, draft, reply and send after the user connects their account and grants access. [Gmail API](https://developers.google.com/workspace/gmail/api/guides), [Outlook API](https://learn.microsoft.com/en-us/graph/api/resources/mail-api-overview). |
| **Apple Mail** | Prepare an email with attachments; the user taps Send. Its standard composition interface does not provide inbox access. [Apple documentation](https://developer.apple.com/documentation/messageui/mfmailcomposeviewcontroller). |
| **Messages / iMessage** | No general access to conversation history. The standard integration prepares a message for the user to review and send. [Apple documentation](https://developer.apple.com/documentation/messageui/mfmessagecomposeviewcontroller). |
| **Apple Notes** | No general public API for full library access. Sharing and user-configured Shortcuts can support workflows such as appending information to a note. [Apple Shortcuts](https://support.apple.com/guide/shortcuts/share-actions-apdaf74d75a5/ios). |

### EU carrier messaging exception

An eligible app selected as the default carrier messaging app can send and receive **SMS, MMS and RCS** through TelephonyMessagingKit. This requires an EU account and a device located in the EU, so it can be relevant to users in Portugal. It does not unlock iMessage.

Source: [Creating a carrier messaging app](https://developer.apple.com/documentation/telephonymessagingkit/creating-a-carrier-messaging-app).

## Other Possible Integrations

Beyond calendars, reminders, Home and alarms, an agent could support:

| Integration | Possible actions |
| --- | --- |
| **Contacts** | Find people and create or update contacts with permission. [Contacts API](https://developer.apple.com/documentation/contacts). |
| **Photos** | Analyze permitted photos, extract information and organize albums. Photo access comes from PhotoKit or a picker; AI analysis requires a separate implementation. [PhotoKit](https://developer.apple.com/documentation/photokit). |
| **Files and PDFs** | Read, summarize and edit documents the user selects. Document access comes from the system picker; parsing, summarization and editing require a separate implementation. [Document access](https://developer.apple.com/documentation/uikit/uidocumentpickerviewcontroller). |
| **Location** | Support nearby searches and arrival or departure triggers with permission. [Core Location](https://developer.apple.com/documentation/corelocation). |

## Example Workflow

> Find the delivery date in my Outlook email, add it to my calendar, remind me the day before, and prepare a message to the customer.

This is a feasible workflow when the app implements the required integrations and the user grants access. The standard message composition interface leaves sending to the user.

## Scope

This document records possible integrations. It does not indicate that these capabilities are already implemented in the current app.
