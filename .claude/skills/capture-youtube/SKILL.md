---
name: capture-youtube
description: Create a literature note from a YouTube video — fetch metadata, summarize content, and link to existing vault notes.
---

# /capture-youtube

## Inputs

- `$1`: a YouTube URL (e.g. `https://www.youtube.com/watch?v=...` or `https://youtu.be/...`).

## Procedure

1. **Extract metadata via yt-dlp.** Run `yt-dlp --dump-json '<url>'` and parse the JSON output for:
   - **Video title** — `title` field.
   - **Channel name** — `channel` or `uploader` field.
   - **Publish date** — `upload_date` field (format `YYYYMMDD`, convert to `YYYY-MM-DD`).
   - **Description** — `description` field.
   - **Chapters** — `chapters` array (each has `start_time` and `title`). Convert `start_time` seconds to `M:SS` or `H:MM:SS`.
   - **Duration** — `duration` field (seconds).

   Use `/usr/bin/python3` for JSON parsing (the system Python — avoid `asdf`-managed python which may not be configured in this repo).

   **Fallback:** If `yt-dlp` is not installed, fall back to oEmbed (`https://www.youtube.com/oembed?url=<url>&format=json`) via WebFetch for title and channel, then inform the user that `brew install yt-dlp` is needed for full captures.

2. **Extract transcript.** Run `yt-dlp --write-auto-sub --sub-lang en --skip-download --sub-format vtt -o '/tmp/yt-transcript' '<url>'` to download auto-generated English subtitles. Then parse the VTT file to extract clean text (strip timestamps, VTT tags, and deduplicate repeated lines). Use `/usr/bin/python3` for parsing.

   If no English auto-subs are available, try `--sub-lang en --write-sub` for manual subs. If neither exists, skip the transcript and note its absence.

   **Important:** Do not include the raw transcript in the note body. Use it to generate the Summary and Key ideas sections.

3. **Generate filename.** Convert the video title to kebab-case: lowercase, replace spaces and special characters with hyphens, collapse consecutive hyphens, strip leading/trailing hyphens. Limit to 60 characters. The file path is `+ Sources/<kebab-slug>.md`.

4. **Check for duplicates.** Grep `+ Sources/` for the YouTube video URL. If a note already exists for this URL, inform the user and offer to update the existing note instead. Do not create a duplicate.

5. **Search for related vault notes.** Extract 3–5 topic keywords from the video title and description. Use Grep to search across `+ Atlas/` and `+ Spaces/` for those keywords (file names and content). Collect up to 10 candidate matches.

6. **Present to the user.** Show the extracted metadata (title, channel, date, description summary) and the list of potentially related vault notes. Ask via `AskUserQuestion`:
   - "Which of these notes should I link in the Related section? Any others to add?"
   - Wait for confirmation before writing.

7. **Write the literature note.** Create the file at the path from step 3 with:

   **Frontmatter:**
   ```yaml
   title: "<video title>"
   source: "YouTube"
   author: "<channel name>"
   url: "<original YouTube URL>"
   published: <YYYY-MM-DD>
   accessed: <today YYYY-MM-DD>
   tags:
     - literature
     - video
   ```

   **Body:**
   ```markdown
   # <video title>

   ## Summary
   <!-- 2-4 sentences synthesized from the transcript, description, and chapters -->

   ## Key ideas
   - <bullet per main point, derived from transcript content>

   ## Chapters
   <!-- Only include if chapters were found in step 1 -->
   - `0:00` — <chapter title>
   - ...

   ## Quotes
   <!-- Notable direct quotes from the transcript; omit section if none -->

   ## My take
   <!-- Left blank for the user -->

   ## Related
   - [[<linked note>]]
   ```

8. **Clean up.** Remove any temporary files created in `/tmp/` (VTT subtitle files).

9. **Confirm output.** Tell the user the file path and a one-line summary of what was captured.

## Output

- New literature note path in `+ Sources/`
- Summary of linked related notes

## Notes

- The Summary and Key ideas sections should be generated from the transcript and description — do not fabricate information not present in the source material.
- Do not include the full transcript in the note body. Distill it into Summary and Key ideas.
- If the video has no description, no transcript, and no extractable content, create the note with placeholder sections and flag with `<!-- TODO: add summary after watching -->`.
- Prefer transcript content over description for generating Summary and Key ideas, as it contains the actual spoken content rather than promotional copy.
