// Automation catalog for cadence.patrick-mckinley.com/automations.html
// Each prompt starts with "Using the Cadence tools" so it works in any MCP client,
// not just Claude.

const CATEGORIES = [
  { id: "day", label: "Your day" },
  { id: "before", label: "Before meetings" },
  { id: "during", label: "During meetings" },
  { id: "after", label: "After meetings" },
  { id: "invites", label: "Invites & clashes" },
  { id: "fun", label: "Just for fun" },
];

// trigger: "demand" | "schedule" | "loop"
const AUTOMATIONS = [
  {
    id: "morning-briefing",
    emoji: "☀️",
    title: "Morning briefing",
    category: "day",
    trigger: "schedule",
    when: "Weekdays, 08:30",
    summary: "Your meetings, back-to-backs, invites waiting for a reply, unresolved clashes and the best gaps for focused work, in under 150 words.",
    tools: ["get_agenda", "list_invites", "list_clashes", "find_free_time"],
    prompt: `Using the Cadence tools, give me a short briefing for today.

1. Call get_agenda for today. List each meeting with its time, title and whether it has a join link. Flag back-to-backs with no break.
2. Call list_invites with horizon "today" and list anything still waiting for my reply.
3. Call list_clashes and point out any overlaps I haven't sorted out.
4. Call find_free_time with duration_minutes 30 (it uses my working hours and keeps my breaks clear), and tell me my best two gaps for focused work.

Keep it under 150 words, in plain sentences, most important thing first. This is read-only: don't reply to invites or change anything.`,
  },
  {
    id: "prep-pack",
    emoji: "🎒",
    title: "Prep pack",
    category: "before",
    trigger: "schedule",
    when: "Every hour in working hours, or before a big meeting",
    summary: "Reads the invite and the documents it links to, then attaches a prep note, the links and a timed agenda to the meeting.",
    tools: ["get_next_meeting", "get_enrichments", "add_enrichment", "update_enrichment"],
    kinds: ["markdown", "links", "agenda"],
    connectors: true,
    prompt: `Using the Cadence tools, prepare me for my next meeting.

1. Call get_next_meeting. If it starts more than 2 hours from now, stop and just tell me when it is.
2. Call get_enrichments for that meeting. If you've already attached a prep note, update it with update_enrichment instead of adding a second one.
3. Read the meeting's notes and any documents or pages linked in them (use my other connected tools, like Google Drive, Notion or the web, if you have them).
4. Attach to the meeting with add_enrichment:
   - kind "markdown", title "Prep": the purpose in one line, 3 to 5 key points from the documents, and open questions I should raise;
   - kind "links", title "Links": every document, ticket or page mentioned, each with a short note;
   - if the notes contain an agenda, kind "agenda", title "Agenda": each item's title and minutes.
5. Tell me in one line what you attached.

Only use what's in the invite and the documents. If something's unclear, say so in the note rather than guessing.`,
  },
  {
    id: "workspace-briefing",
    emoji: "🗂️",
    title: "Google Workspace briefing",
    category: "before",
    trigger: "schedule",
    when: "Weekdays, 08:00, for the day's meetings",
    summary: "Pulls together Drive docs, recent Gmail threads, a matching NotebookLM notebook and the Gemini notes from last time, then pins a brief, the actions still open and every source to each meeting.",
    tools: ["get_agenda", "get_enrichments", "add_enrichment", "update_enrichment"],
    kinds: ["markdown", "log", "links"],
    connectors: true,
    prompt: `Using the Cadence tools and my Google Workspace connectors (Google Drive, Gmail, and NotebookLM if you have it), get today's meetings ready.

1. Call get_agenda for today. Skip declined meetings, all-day events and blocks with no other attendees.
2. For each remaining meeting, call get_enrichments. If you've already attached items with the ids "ws-brief", "ws-actions" or "ws-sources", update them with update_enrichment instead of adding new ones.
3. Look for material, newest first, and keep track of where each fact came from:
   - Google Drive: documents linked in the invite; the "Notes by Gemini" documents from the last 3 times this meeting (or a meeting with the same title) happened, reading their summary and suggested next steps; and documents from the last 30 days that mention the meeting's title or project and were shared by or edited by an attendee.
   - Gmail: threads from the last 14 days with the attendees that are about this meeting's topic. Note any questions or requests addressed to me.
   - NotebookLM: if a notebook clearly matches the project, ask it for the key points and open questions on this meeting's topic. Otherwise skip it.
4. Attach to the meeting with add_enrichment:
   - kind "markdown", id "ws-brief", title "Brief": the purpose in one line, what's changed since last time, 3 to 5 key points each with its source in brackets, and anything people are waiting on from me;
   - kind "log", id "ws-actions", title "Open actions": each next step from the previous Gemini notes as type "action" with its owner and due date. Leave out any that a later email or doc shows were done, and add a note entry saying which ones you dropped and why;
   - kind "links", id "ws-sources", title "Sources": every document, thread and notebook you used, each with a one-line note.
5. Finish with one line per meeting saying what you attached, and which meetings you found nothing for.

Rules: only use material I can already open, and quote or summarise it briefly rather than copying whole documents. If any attendees are outside my organisation, leave out internal-only documents and threads. Don't send email, share files or change any document. If sources disagree or something's unclear, say so in the brief instead of guessing.`,
  },
  {
    id: "workspace-briefing-live",
    emoji: "📥",
    title: "Brief new invites as they land",
    category: "invites",
    trigger: "loop",
    summary: "The live version of the Google Workspace briefing: when a new invite for today arrives, or a meeting moves into today, it gathers Drive, Gmail, NotebookLM and earlier Gemini notes and pins a brief straight away.",
    tools: ["wait_for_event", "get_enrichments", "add_enrichment", "update_enrichment", "list_clashes"],
    kinds: ["markdown", "log", "links"],
    connectors: true,
    prompt: `Using the Cadence tools and my Google Workspace connectors (Google Drive, Gmail, and NotebookLM if you have it), brief me on new meetings as they turn up today.

Repeat until I tell you to stop:
1. Call wait_for_event with types ["invite.new", "meeting.changed"] and timeout_seconds 300. If nothing comes back, go round again.
2. Each event's data has the meeting (its id, title, start time and attendees). Only carry on for meetings that start later today. For "meeting.changed", call get_enrichments first and skip the meeting if it already has an item with the id "ws-brief" (it's been briefed).
3. Look for material, newest first, and keep track of where each fact came from:
   - Google Drive: documents linked in the invite; "Notes by Gemini" from the last 3 times a meeting with this title happened (their summary and suggested next steps); and documents from the last 30 days about the meeting's topic shared or edited by an attendee.
   - Gmail: threads from the last 14 days with the attendees about this topic, including anything addressed to me.
   - NotebookLM: if a notebook clearly matches the project, ask it for key points and open questions. Otherwise skip it.
4. Attach with add_enrichment (or update_enrichment if the id already exists):
   - kind "markdown", id "ws-brief", title "Brief": the purpose in one line, what's changed since last time, 3 to 5 key points each with its source, and anything people are waiting on from me;
   - kind "log", id "ws-actions", title "Open actions": next steps from earlier Gemini notes that still look open, as type "action" with owner and due date;
   - kind "links", id "ws-sources", title "Sources": every document, thread and notebook you used.
5. Call list_clashes. Then tell me in two lines: what the meeting is and when, what you attached, and whether it clashes with anything.

Rules: only use material I can already open, and summarise rather than copy whole documents. If any attendees are outside my organisation, leave out internal-only material. Never reply to the invite, send email, share files or change a document. If you find nothing useful, attach nothing and just say so.`,
  },
  {
    id: "m365-briefing",
    emoji: "🏢",
    title: "Microsoft 365 briefing",
    category: "before",
    trigger: "schedule",
    when: "Weekdays, 08:00, for the day's meetings",
    summary: "The Microsoft 365 take: pulls SharePoint and OneDrive files, recent Outlook mail and Teams chats, and the recap and follow-ups from last time, then pins a brief, the actions still open and every source to each meeting.",
    tools: ["get_agenda", "get_enrichments", "add_enrichment", "update_enrichment"],
    kinds: ["markdown", "log", "links"],
    connectors: true,
    prompt: `Using the Cadence tools and my Microsoft 365 connectors (SharePoint and OneDrive, Outlook, and Teams if you have them), get today's meetings ready.

1. Call get_agenda for today. Skip declined meetings, all-day events and blocks with no other attendees.
2. For each remaining meeting, call get_enrichments. If you've already attached items with the ids "m365-brief", "m365-actions" or "m365-sources", update them with update_enrichment instead of adding new ones.
3. Look for material, newest first, and keep track of where each fact came from:
   - SharePoint and OneDrive: files linked in the invite or shared in the meeting's chat; files from the last 30 days that mention the meeting's title or project and were shared or edited by an attendee; and the project's SharePoint site or Teams channel files if there's an obvious one.
   - Previous meetings: for the last 3 times this meeting (or one with the same title) happened, the Teams recap (AI notes and follow-up tasks from Copilot or Teams Premium), the meeting notes or Loop page, or the transcript if that's all there is.
   - Outlook: email threads from the last 14 days with the attendees about this topic. Note any questions or requests addressed to me.
   - Teams: the meeting's own chat and recent messages in the matching channel or group chat.
   - Planner or To Do: tasks linked to the meeting or assigned from its last recap, if you can see them.
4. Attach to the meeting with add_enrichment:
   - kind "markdown", id "m365-brief", title "Brief": the purpose in one line, what's changed since last time, 3 to 5 key points each with its source in brackets, and anything people are waiting on from me;
   - kind "log", id "m365-actions", title "Open actions": each follow-up from the previous recaps as type "action" with its owner and due date. Leave out any that a later email, chat or task shows were done, and add a note entry saying which ones you dropped and why;
   - kind "links", id "m365-sources", title "Sources": every file, thread, chat and recap you used, each with a one-line note.
5. Finish with one line per meeting saying what you attached, and which meetings you found nothing for.

Rules: only use material I can already open, and summarise rather than copy whole documents. Respect sensitivity labels: if any attendees are outside my organisation, leave out anything labelled Confidential or above, and anything else meant for internal use only. Don't send email or chat messages, share files, or change any document or task. If sources disagree or something's unclear, say so in the brief instead of guessing.`,
  },
  {
    id: "m365-briefing-live",
    emoji: "📨",
    title: "Brief new Microsoft 365 invites as they land",
    category: "invites",
    trigger: "loop",
    summary: "The live version of the Microsoft 365 briefing: when a new invite for today arrives, or a meeting moves into today, it gathers SharePoint, OneDrive, Outlook, Teams and the last recap and pins a brief straight away.",
    tools: ["wait_for_event", "get_enrichments", "add_enrichment", "update_enrichment", "list_clashes"],
    kinds: ["markdown", "log", "links"],
    connectors: true,
    prompt: `Using the Cadence tools and my Microsoft 365 connectors (SharePoint and OneDrive, Outlook, and Teams if you have them), brief me on new meetings as they turn up today.

Repeat until I tell you to stop:
1. Call wait_for_event with types ["invite.new", "meeting.changed"] and timeout_seconds 300. If nothing comes back, go round again.
2. Each event's data has the meeting (its id, title, start time and attendees). Only carry on for meetings that start later today. For "meeting.changed", call get_enrichments first and skip the meeting if it already has an item with the id "m365-brief" (it's been briefed).
3. Look for material, newest first, and keep track of where each fact came from:
   - SharePoint and OneDrive: files linked in the invite, and files from the last 30 days about the meeting's topic shared or edited by an attendee.
   - Previous meetings: the Teams recap (AI notes and follow-up tasks), meeting notes or Loop page from the last 3 times a meeting with this title happened.
   - Outlook and Teams: email threads and chats from the last 14 days with the attendees about this topic, including anything addressed to me.
4. Attach with add_enrichment (or update_enrichment if the id already exists):
   - kind "markdown", id "m365-brief", title "Brief": the purpose in one line, what's changed since last time, 3 to 5 key points each with its source, and anything people are waiting on from me;
   - kind "log", id "m365-actions", title "Open actions": follow-ups from earlier recaps that still look open, as type "action" with owner and due date;
   - kind "links", id "m365-sources", title "Sources": every file, thread, chat and recap you used.
5. Call list_clashes. Then tell me in two lines: what the meeting is and when, what you attached, and whether it clashes with anything.

Rules: only use material I can already open, and summarise rather than copy whole documents. Respect sensitivity labels: if any attendees are outside my organisation, leave out anything labelled Confidential or above, and anything else meant for internal use only. Never reply to the invite, send email or chat messages, share files or change a document. If you find nothing useful, attach nothing and just say so.`,
  },
  {
    id: "whos-who",
    emoji: "🪪",
    title: "Who's who",
    category: "before",
    trigger: "demand",
    summary: "A card of everyone in the meeting: name, role and what they're likely to care about, from your directory, email and chat.",
    tools: ["get_next_meeting", "add_enrichment"],
    kinds: ["people"],
    connectors: true,
    prompt: `Using the Cadence tools, add a "Who's who" card to my next meeting.

1. Call get_next_meeting. Cadence gives you the organiser and how many people are invited, but not the full guest list, so look the meeting up in my calendar connector (Google Calendar or Outlook) to get the attendees.
2. For each person, find their role and team from my directory, email or chat tools if you have them. Add one short note on what they're likely to care about in this meeting, based on recent threads with them.
3. Attach it with add_enrichment: kind "people", title "Who's who", one item per person with name, email, role and notes. Put the organiser first.

Never invent job titles or facts. If you can't find something, leave it out.`,
  },
  {
    id: "timed-agenda",
    emoji: "⏱️",
    title: "Timed agenda from the invite",
    category: "before",
    trigger: "demand",
    summary: "Turns the topics in an invite into an agenda that fits the meeting. Cadence highlights the current item and shows when it runs over.",
    tools: ["get_next_meeting", "add_enrichment"],
    kinds: ["agenda"],
    prompt: `Using the Cadence tools, turn my next meeting's invite into a timed agenda.

1. Call get_next_meeting and read its notes and how long it is.
2. Pull out the topics. If the notes don't list any, ask me for them instead of making some up.
3. Share the time between them so the total fits the meeting with 5 minutes spare at the end. Keep the order from the invite.
4. Attach it with add_enrichment: kind "agenda", title "Agenda", one item per topic with title, minutes and owner (when the invite names one).`,
  },
  {
    id: "one-on-one",
    emoji: "🤝",
    title: "1:1 running list",
    category: "before",
    trigger: "demand",
    summary: "One talking-points checklist that follows a recurring 1:1 from week to week. Ticked points drop off, the rest carry forward.",
    tools: ["get_agenda", "get_enrichments", "add_enrichment", "update_enrichment"],
    kinds: ["checklist"],
    placeholders: true,
    prompt: `Using the Cadence tools, keep a running list of talking points for my recurring 1:1 with {name}.

1. Call get_agenda for today and tomorrow and find the next 1:1 with {name}.
2. Call get_enrichments on it. If there's a "Talking points" checklist, keep it. Otherwise add one with add_enrichment: kind "checklist", title "Talking points", all_occurrences true.
3. Remove the points that were ticked off last time and carry the rest forward.
4. Ask me what I want to cover this time, and add the new points with update_enrichment.`,
  },
  {
    id: "key-numbers",
    emoji: "📈",
    title: "Key numbers",
    category: "before",
    trigger: "schedule",
    when: "An hour before the meeting",
    summary: "Puts the latest figures from a spreadsheet or dashboard on the meeting, with change since last time and whether that's good.",
    tools: ["get_agenda", "get_enrichments", "add_enrichment", "update_enrichment"],
    kinds: ["stats"],
    connectors: true,
    placeholders: true,
    prompt: `Using the Cadence tools, put the key numbers on my next "{meeting name}" meeting.

1. Find the meeting with get_agenda (today or tomorrow).
2. Get the latest figures from {where they live, e.g. the "Weekly KPIs" sheet in Google Drive}. Use only real numbers you can see. Never estimate or fill gaps.
3. Call get_enrichments. If the meeting already has a "Key numbers" card, update it with update_enrichment. Otherwise attach one with add_enrichment: kind "stats", title "Key numbers", up to 6 items with label, value, delta against last time, trend ("up", "down" or "flat") and up_is_good (false for things like cost or churn).
4. Tell me where each number came from.`,
  },
  {
    id: "interview-kit",
    emoji: "🧑‍💼",
    title: "Interview kit",
    category: "before",
    trigger: "demand",
    summary: "Candidate card, questions to tick off as you go, and a scoring guide, attached to the interview.",
    tools: ["get_agenda", "add_enrichment"],
    kinds: ["people", "checklist", "markdown"],
    connectors: true,
    prompt: `Using the Cadence tools, build an interview kit for my next interview.

1. Call get_agenda and find the next meeting that looks like an interview (the title usually says "interview" or has the candidate's name). Check with me if you're not sure.
2. Find the candidate's CV and the role description in my connected files or email.
3. Attach to the meeting with add_enrichment:
   - kind "people", title "Candidate": their name, the role, and one line of background from the CV;
   - kind "checklist", title "Questions": 6 to 8 questions for this role, including two that dig into the CV;
   - kind "markdown", title "Scoring": what a strong, an OK and a weak answer looks like for the main skills.

Keep it to what's relevant to the job.`,
  },
  {
    id: "decisions-log",
    emoji: "📝",
    title: "Decisions & actions log",
    category: "during",
    trigger: "demand",
    summary: "A log on the meeting for decisions, actions and notes, which you fill in from the Notes drawer while you talk.",
    tools: ["get_next_meeting", "get_enrichments", "add_enrichment"],
    kinds: ["log"],
    prompt: `Using the Cadence tools, set up a decisions and actions log for my next meeting.

1. Call get_next_meeting, then get_enrichments to see if it already has a log.
2. If it doesn't, attach one with add_enrichment: kind "log", title "Decisions & actions". Start it with a single item of type "note" stating the meeting's goal, taken from the invite.
3. Tell me it's there. I'll add decisions and actions during the meeting from Cadence's Notes drawer.

After the meeting, when I ask, call get_enrichments again and list the decisions, then the actions with their owners and due dates.`,
  },
  {
    id: "follow-up",
    emoji: "📮",
    title: "Follow-up after every meeting",
    category: "after",
    trigger: "loop",
    summary: "Waits for each meeting to end, reads what was logged and ticked, and drafts a follow-up for you to check. Never sends on its own.",
    tools: ["wait_for_event", "get_enrichments"],
    connectors: true,
    prompt: `Using the Cadence tools, help me follow up after my meetings today.

Repeat until the end of my working day:
1. Call wait_for_event with types ["meeting.ended"] and timeout_seconds 300. If nothing comes back, go round again.
2. When a meeting ends, call get_enrichments for it. Look at the log entries, ticked checklist items and anything I typed.
3. If there are decisions or actions, draft a short follow-up to the attendees: what we decided and who's doing what by when. Save it as a draft with my email or chat connector.
4. Tell me the draft is ready. Never send anything without asking me first.

If a meeting had nothing logged, skip it quietly.`,
  },
  {
    id: "end-of-day",
    emoji: "🌇",
    title: "End-of-day wrap-up",
    category: "after",
    trigger: "schedule",
    when: "Weekdays, 17:30",
    summary: "Gathers every action from today's meeting notes, mine first, then a heads-up on tomorrow's first meeting.",
    tools: ["get_agenda", "get_enrichments"],
    prompt: `Using the Cadence tools, wrap up my day.

1. Call get_agenda for today. For each meeting with notes attached (enrichment_count above 0), call get_enrichments.
2. Collect every action: log items of type "action" and unticked checklist items, with owner and due date when there is one.
3. Give me a short list: my actions first, then other people's I should chase.
4. Call get_agenda for tomorrow and tell me when my first meeting is and anything I should prepare tonight.`,
  },
  {
    id: "invite-triage",
    emoji: "📬",
    title: "Invite triage",
    category: "invites",
    trigger: "demand",
    summary: "Suggests accept, maybe or decline for every pending invite, with a reason, then replies to the ones you agree with.",
    tools: ["list_invites", "list_clashes", "get_agenda", "respond_to_invite"],
    prompt: `Using the Cadence tools, help me clear my invites.

1. Call list_invites with horizon "week".
2. Call list_clashes, and get_agenda for today and tomorrow, so you know what each invite would collide with.
3. For each invite, suggest accept, tentative or decline with a one-line reason (a clash, outside working hours, no agenda, I'm optional, and so on). Show them as a list.
4. Wait for me. When I say which to go ahead with, call respond_to_invite for each one. Cadence will ask me to approve every reply.`,
  },
  {
    id: "clash-fixer",
    emoji: "🥊",
    title: "Clash fixer",
    category: "invites",
    trigger: "demand",
    summary: "Works out which of two overlapping meetings matters more, and suggests what to do with the other.",
    tools: ["list_clashes", "get_agenda", "find_free_time", "respond_to_invite"],
    prompt: `Using the Cadence tools, sort out my double bookings.

1. Call list_clashes.
2. For each clash, look at both meetings (get_agenda for that day) and tell me which looks more important and why: who organised it, how many people are invited, whether it recurs, whether I'm needed.
3. Suggest what to do with the other one: decline, mark tentative, or ask to move it. If moving makes sense, call find_free_time to suggest a new slot.
4. Only call respond_to_invite once I agree, and Cadence will ask me to approve each reply. If someone needs asking to move a meeting, draft the message and don't send it.`,
  },
  {
    id: "colour-code",
    emoji: "🎨",
    title: "Colour-code my day",
    category: "day",
    trigger: "demand",
    summary: "Sorts today's meetings into focus, 1:1s, team, external and interviews, and colours them to match.",
    tools: ["list_calendars", "get_agenda", "set_event_color"],
    prompt: `Using the Cadence tools, colour-code my calendar for today.

1. Call list_calendars and get_agenda for today.
2. Sort the meetings into: focus time, 1:1s, team meetings, external or client meetings, and interviews.
3. Suggest a colour for each group from Tomato, Flamingo, Tangerine, Banana, Sage, Basil, Peacock, Blueberry, Lavender, Grape and Graphite (or my own colour label names, if I've set any), and show me the plan.
4. Once I agree, call set_event_color for each meeting. Cadence asks me to approve each change. Colours only stick on Google calendars, so skip events from other calendars.`,
  },
  {
    id: "focus-time",
    emoji: "🎧",
    title: "Protect focus time",
    category: "day",
    trigger: "schedule",
    when: "Weekdays, first thing",
    summary: "Finds the best 90-minute gaps today and tomorrow and, with your OK, blocks them out in your calendar.",
    tools: ["find_free_time"],
    connectors: true,
    prompt: `Using the Cadence tools, protect some focus time.

1. Call find_free_time with duration_minutes 90 for today and tomorrow. It already sticks to my working hours and keeps my breaks clear.
2. Pick up to two slots, preferring mornings and avoiding the last hour of the day.
3. Show me the slots. Cadence can't create events, so once I agree, add "Focus time" events with my calendar connector (Google Calendar or Outlook), marked as busy.
4. If you don't have a calendar connector, just give me the times so I can add them.`,
  },
  {
    id: "tomorrow-prepped",
    emoji: "🌙",
    title: "Tomorrow, prepped",
    category: "before",
    trigger: "schedule",
    when: "Weekdays, 18:00",
    summary: "Each evening, goes through tomorrow's meetings and attaches a prep note and links to every one that has documents, so the morning starts ready.",
    tools: ["get_agenda", "get_enrichments", "add_enrichment", "update_enrichment"],
    kinds: ["markdown", "links"],
    connectors: true,
    prompt: `Using the Cadence tools, get tomorrow's meetings ready tonight.

1. Call get_agenda for tomorrow.
2. Skip meetings with no notes or links in the invite, focus time, and anything I've declined.
3. For each of the rest, call get_enrichments. If you've already attached a "Prep" note, update it with update_enrichment rather than adding another.
4. Read the documents and pages linked in the invite (with my other connected tools, if you have them) and attach with add_enrichment:
   - kind "markdown", title "Prep": the purpose in one line, 3 key points and any decision I'm expected to make;
   - kind "links", title "Links": each document or page, with a short note.
5. Finish with a two-line summary: how many meetings you prepped, and the one that needs the most thought.

Only use what's in the invites and the documents. Don't reply to anything or change the meetings.`,
  },
  {
    id: "break-defender",
    emoji: "🥪",
    title: "Break defender",
    category: "invites",
    trigger: "schedule",
    when: "Weekdays, 08:00",
    summary: "Finds invites and meetings that land on your lunch, your other breaks or outside your hours, and offers polite ways out.",
    tools: ["find_free_time", "list_invites", "get_agenda", "respond_to_invite"],
    prompt: `Using the Cadence tools, look after my breaks and working hours today and tomorrow.

1. Call find_free_time with duration_minutes 15. Its result lists my working_hours and the breaks_kept_clear (set in Cadence's Work settings). Use those as my hours and breaks.
2. Call list_invites with horizon "twoDays" and get_agenda for today and tomorrow.
3. List every invite or meeting that overlaps a break or falls outside my hours, with how much it overlaps.
4. For each, suggest one of: decline, mark tentative, or ask the organiser to move it. If moving, call find_free_time with the meeting's length and suggest a slot.
5. Wait for me. Only call respond_to_invite for the ones I agree to, and Cadence will ask me to approve each reply. Draft any "could we move this?" messages, but don't send them.

Keep it friendly: suggest the wording, not excuses.`,
  },
  {
    id: "back-to-back",
    emoji: "🏃",
    title: "Back-to-back rescue",
    category: "during",
    trigger: "loop",
    summary: "When a meeting's about to end and the next one starts straight after, warns you and gets the next one's key points ready.",
    tools: ["wait_for_event", "get_next_meeting", "get_enrichments"],
    prompt: `Using the Cadence tools, help me through back-to-back meetings today.

Repeat until I tell you to stop:
1. Call wait_for_event with types ["meeting.ending_soon"] and timeout_seconds 300. If nothing comes back, go round again.
2. When a meeting is ending soon, call get_next_meeting. If it starts within 5 minutes of the current one ending, it's a back-to-back.
3. For a back-to-back, tell me in two lines: what's next and when, and the one thing to have ready (from the invite, or from get_enrichments if it has notes).
4. If the gap is zero, remind me that Cadence's alert has a "Running late?" button to let them know, and offer to draft a one-line note I can paste instead.

Don't send anything or join anything yourself.`,
  },
  {
    id: "panel-declutter",
    emoji: "🧹",
    title: "Declutter the countdown",
    category: "day",
    trigger: "demand",
    summary: "Spots the holds, FYIs and all-hands you never actually attend, and offers to hide them from Cadence's floating countdown.",
    tools: ["get_agenda", "hide_from_panel"],
    prompt: `Using the Cadence tools, help me tidy up which meetings Cadence counts down to.

1. Call get_agenda for today and tomorrow.
2. Pick out meetings I probably don't need a countdown for: placeholders and holds ("Hold", "Block", "OOO", "Focus"), FYI or optional events, big broadcasts with lots of attendees, and anything with no join link and no location that looks like a reminder rather than a meeting.
3. Show them as a short list with a one-line reason each, and say which ones are recurring.
4. Wait for me to choose. For each one I pick, call hide_from_panel with its meeting_id, and all_occurrences true only if I say "every time". Cadence will ask me to confirm each one.

Never hide anything I haven't picked. Hiding only removes it from the countdown; it stays in my calendar.`,
  },
  {
    id: "meeting-load",
    emoji: "📊",
    title: "Meeting load check",
    category: "day",
    trigger: "schedule",
    when: "Weekdays, 17:00",
    summary: "How much of tomorrow is meetings, your longest stretch without a gap, and how much focus time is left, pinned as numbers on tomorrow's first meeting.",
    tools: ["get_agenda", "find_free_time", "add_enrichment"],
    kinds: ["stats"],
    prompt: `Using the Cadence tools, size up tomorrow.

1. Call find_free_time with duration_minutes 15 for tomorrow. Note the working_hours it reports and the free slots.
2. Call get_agenda for tomorrow (skip declined meetings).
3. Work out:
   - hours in meetings, and that as a percentage of my working hours;
   - number of meetings;
   - my longest run of meetings with less than 10 minutes between them;
   - total free time in slots of 60 minutes or more ("focus time left").
4. Tell me in two sentences, and say plainly if tomorrow looks overloaded (more than 70% in meetings, or a run longer than 3 hours).
5. Call add_enrichment on tomorrow's first meeting with kind "stats", id "meeting-load" and title "Tomorrow at a glance", with items for each number. Use up_is_good false for meeting hours and the longest run, and true for focus time left.

Don't change any meetings.`,
  },
  {
    id: "change-watcher",
    emoji: "🔔",
    title: "Last-minute change watcher",
    category: "invites",
    trigger: "loop",
    summary: "Keeps an eye on today: tells you when a meeting moves, gets cancelled or a new clash appears, and what that does to the rest of your day.",
    tools: ["wait_for_event", "get_agenda", "list_clashes", "find_free_time"],
    prompt: `Using the Cadence tools, watch my calendar for changes for the rest of today.

Repeat until I tell you to stop:
1. Call wait_for_event with timeout_seconds 300 (all event types). If nothing comes back, go round again.
2. Ignore routine events (meetings starting, ending or about to start, and presenting or call status).
3. When a meeting is moved, cancelled or changed, a new invite arrives, or a new clash appears:
   - call get_agenda for today and say in one line what changed and when;
   - call list_clashes and mention any overlap it creates;
   - if a meeting was cancelled, call find_free_time with duration_minutes 30 for today and say if that opened up a useful gap.
4. Keep each update to three lines at most.

Only tell me about things. Don't reply to invites, hide meetings or change anything.`,
  },
  {
    id: "co-pilot",
    emoji: "🛰️",
    title: "Meeting co-pilot",
    category: "after",
    trigger: "loop",
    summary: "Runs all day: preps each meeting as it gets close, drafts follow-ups when it ends, and tells you about new invites.",
    tools: ["wait_for_event", "get_enrichments", "add_enrichment"],
    kinds: ["markdown", "links"],
    connectors: true,
    prompt: `Using the Cadence tools, be my meeting co-pilot until I say stop.

Keep calling wait_for_event with types ["meeting.starting_soon", "meeting.ended", "invite.new"] and timeout_seconds 300, and for each event:
- meeting.starting_soon: if get_enrichments shows the meeting has no notes yet, attach a short "Prep" markdown note and a "Links" list, from the invite and the documents it links to.
- meeting.ended: read the meeting's notes with get_enrichments. If there are actions, draft a follow-up and tell me about it.
- invite.new: tell me about it in one line, including any clash.

Keep each message short. Never reply to invites, join meetings or send messages without asking me.`,
  },
  {
    id: "bingo",
    emoji: "🎯",
    title: "All-hands buzzword bingo",
    category: "fun",
    trigger: "demand",
    summary: "A 5×5 card of good-natured meeting clichés on every all-hands. Tap squares as people say them.",
    tools: ["get_agenda", "add_enrichment"],
    kinds: ["bingo"],
    prompt: `Using the Cadence tools, make a buzzword bingo card for our all-hands.

1. Call get_agenda for today and tomorrow and find the meeting with "all-hands" (or "town hall") in the title. If there's more than one, ask me which.
2. Write 40 short, good-natured phrases people say in meetings like this, such as "Let's take this offline", "Can everyone see my screen?", "You're on mute", "Circle back" and "Quick shout-out to…". Nothing that singles out a real person.
3. Attach it with add_enrichment: kind "bingo", title "All-hands bingo", content with all 40 squares, size 5 and free_centre true, and all_occurrences true so it's there every time the series comes round.`,
  },
  {
    id: "bingo-announcer",
    emoji: "📣",
    title: "Bingo announcer",
    category: "fun",
    trigger: "loop",
    summary: "Listens for a completed line on any bingo card and celebrates the winning row.",
    tools: ["wait_for_event", "get_enrichments"],
    prompt: `Using the Cadence tools, watch for bingo during my meetings.

Repeat until I tell you to stop:
1. Call wait_for_event with types ["enrichment.bingo"] and timeout_seconds 300. If nothing comes back, go round again.
2. When a bingo arrives, call get_enrichments for that meeting and see which squares are marked.
3. Reply with one celebratory line naming the squares that won, like "BINGO! 'Circle back' finished the top row."

Don't post anywhere else unless I've asked you to.`,
  },
];

const TRIGGERS = {
  demand: { label: "On demand", hint: "Run it whenever you like." },
  schedule: { label: "Scheduled", hint: "Save it as a scheduled task." },
  loop: { label: "Runs in the background", hint: "Keeps going while the chat or task stays open." },
};

const ACT_TOOLS = new Set(["respond_to_invite", "set_event_color", "join_meeting", "hide_from_panel", "snooze_alert"]);
const ATTACH_TOOLS = new Set(["add_enrichment", "update_enrichment", "remove_enrichment", "clear_enrichments"]);

function asMarkdown(a) {
  const trigger = TRIGGERS[a.trigger].label + (a.when ? ` (${a.when})` : "");
  return [
    "---",
    `title: ${JSON.stringify(a.title)}`,
    `description: ${JSON.stringify(a.summary)}`,
    `trigger: ${JSON.stringify(trigger)}`,
    `tools: [${a.tools.join(", ")}]`,
    `source: https://cadence.patrick-mckinley.com/automations.html#${a.id}`,
    "---",
    "",
    a.prompt,
    "",
  ].join("\n");
}

function download(filename, text) {
  const blob = new Blob([text], { type: "text/markdown;charset=utf-8" });
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = filename;
  document.body.appendChild(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

async function copyText(text, button) {
  try {
    await navigator.clipboard.writeText(text);
  } catch {
    const area = document.createElement("textarea");
    area.value = text;
    area.style.position = "fixed";
    area.style.opacity = "0";
    document.body.appendChild(area);
    area.select();
    try { document.execCommand("copy"); } catch {}
    area.remove();
  }
  const old = button.textContent;
  button.textContent = "Copied ✓";
  button.classList.add("done");
  setTimeout(() => { button.textContent = old; button.classList.remove("done"); }, 1600);
}

function el(tag, attrs = {}, ...children) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(attrs)) {
    if (key === "class") node.className = value;
    else if (key === "text") node.textContent = value;
    else node.setAttribute(key, value);
  }
  for (const child of children) if (child) node.append(child);
  return node;
}

function card(a) {
  const category = CATEGORIES.find((c) => c.id === a.category);
  const asks = a.tools.some((t) => ACT_TOOLS.has(t));
  const attaches = a.tools.some((t) => ATTACH_TOOLS.has(t));

  const badges = el("div", { class: "auto-badges" },
    el("span", { class: `tbadge t-${a.trigger}`, text: TRIGGERS[a.trigger].label, title: TRIGGERS[a.trigger].hint }),
    attaches ? el("span", { class: "tbadge t-attach", text: "Attaches notes" }) : null,
    asks ? el("span", { class: "tbadge t-asks", text: "Asks first in Cadence", title: "Cadence shows an Allow / Deny card before this happens" }) : null,
    a.connectors ? el("span", { class: "tbadge t-conn", text: "Uses your other connectors", title: "Works best with calendar, files, email or chat connectors in your assistant" }) : null,
  );

  const tools = el("div", { class: "auto-tools" }, ...a.tools.map((t) => el("code", { text: t })));
  const pre = el("pre", { class: "prompt", id: `prompt-${a.id}` }, el("code", { text: a.prompt }));
  const details = el("details", { class: "auto-prompt" }, el("summary", { text: "Show prompt" }), pre);

  const copy = el("button", { type: "button", class: "btn", text: "Copy prompt" });
  copy.addEventListener("click", () => copyText(a.prompt, copy));
  const dl = el("button", { type: "button", class: "btn ghost", text: "Download .md" });
  dl.addEventListener("click", () => download(`cadence-${a.id}.md`, asMarkdown(a)));

  const article = el("article", { class: "auto-card", id: a.id, "data-category": a.category },
    el("div", { class: "auto-top" },
      el("span", { class: "auto-emoji", "aria-hidden": "true", text: a.emoji }),
      el("span", { class: "auto-cat", text: category.label }),
    ),
    el("h3", { text: a.title }),
    el("p", { class: "auto-summary", text: a.summary }),
    a.when ? el("p", { class: "auto-when", text: `Suggested schedule: ${a.when}` }) : null,
    a.placeholders ? el("p", { class: "auto-when", text: "Fill in the {…} parts before you run it." }) : null,
    badges,
    tools,
    details,
    el("div", { class: "auto-actions" }, copy, dl),
  );
  article.dataset.search = [a.title, a.summary, a.prompt, category.label, ...a.tools, ...(a.kinds || [])].join(" ").toLowerCase();
  return article;
}

function renderCatalog() {
  const grid = document.getElementById("catalog");
  const chips = document.getElementById("chips");
  const search = document.getElementById("search");
  const count = document.getElementById("count");
  if (!grid) return;

  const cards = AUTOMATIONS.map(card);
  grid.replaceChildren(...cards);

  let current = "all";
  const all = [{ id: "all", label: "All" }, ...CATEGORIES];
  for (const c of all) {
    const n = c.id === "all" ? AUTOMATIONS.length : AUTOMATIONS.filter((a) => a.category === c.id).length;
    const chip = el("button", { type: "button", class: "chip", "aria-pressed": String(c.id === "all") }, c.label, el("span", { text: String(n) }));
    chip.addEventListener("click", () => {
      current = c.id;
      for (const other of chips.children) other.setAttribute("aria-pressed", String(other === chip));
      apply();
    });
    chips.append(chip);
  }

  function apply() {
    const q = search.value.trim().toLowerCase();
    let shown = 0;
    for (const node of cards) {
      const ok = (current === "all" || node.dataset.category === current) && (!q || node.dataset.search.includes(q));
      node.hidden = !ok;
      if (ok) shown += 1;
    }
    count.textContent = shown === AUTOMATIONS.length ? `${shown} automations` : `${shown} of ${AUTOMATIONS.length}`;
    document.getElementById("empty").hidden = shown !== 0;
  }
  search.addEventListener("input", apply);
  apply();

  document.getElementById("download-all").addEventListener("click", () => {
    const body = AUTOMATIONS.map((a) => `## ${a.emoji} ${a.title}\n\n${a.summary}\n\nTrigger: ${TRIGGERS[a.trigger].label}${a.when ? ` (${a.when})` : ""}\nTools: ${a.tools.join(", ")}\n\n\`\`\`text\n${a.prompt}\n\`\`\`\n`).join("\n");
    download("cadence-automations.md", `# Cadence automation prompts\n\nFrom https://cadence.patrick-mckinley.com/automations.html\n\n${body}`);
  });

  // Open a card linked by #id.
  if (location.hash) {
    const target = document.getElementById(location.hash.slice(1));
    if (target && target.classList.contains("auto-card")) {
      target.querySelector("details").open = true;
      target.classList.add("flash");
      target.scrollIntoView({ block: "start" });
    }
  }
}

function setupTabs() {
  const tabs = document.querySelectorAll("[role=tab]");
  for (const tab of tabs) {
    tab.addEventListener("click", () => {
      for (const t of tabs) {
        const on = t === tab;
        t.setAttribute("aria-selected", String(on));
        t.tabIndex = on ? 0 : -1;
        document.getElementById(t.getAttribute("aria-controls")).hidden = !on;
      }
      // Keep the chosen tab visible when the row scrolls sideways on a phone.
      const row = tab.parentElement;
      const left = tab.offsetLeft - row.offsetLeft, right = left + tab.offsetWidth;
      if (left < row.scrollLeft || right > row.scrollLeft + row.clientWidth) {
        row.scrollTo({ left: Math.max(0, left - 8), behavior: "smooth" });
      }
    });
    tab.addEventListener("keydown", (e) => {
      if (e.key !== "ArrowRight" && e.key !== "ArrowLeft") return;
      const list = [...tabs];
      const next = list[(list.indexOf(tab) + (e.key === "ArrowRight" ? 1 : list.length - 1)) % list.length];
      next.click();
      next.focus();
    });
  }
  for (const link of document.querySelectorAll("a[data-tab]")) {
    link.addEventListener("click", () => document.getElementById(link.dataset.tab)?.click());
  }
  for (const button of document.querySelectorAll("[data-copy]")) {
    button.addEventListener("click", () => copyText(document.getElementById(button.dataset.copy).textContent.trim(), button));
  }
}

setupTabs();
renderCatalog();
