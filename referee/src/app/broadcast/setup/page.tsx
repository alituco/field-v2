import styles from "@/components/broadcaster-laptop-panel.module.css";

export default function BroadcastSetupPage() {
  return (
    <main className={styles.guide}>
      <a className={styles.guideLink} href="/">← Back to match day</a>
      <h1>Your pitch. Live.</h1>
      <p>Set up your Mac and Osmo before the match, then manage the stream from your phone.</p>
      <ol className={styles.steps}>
        <li><h2>Set up the Mac</h2><p>Open Fieldrush Broadcaster and follow its OBS setup instructions. Use the Fieldrush app supplied by your organizer. Connect the Mac to power and reliable internet, and keep the lid open during the game.</p></li>
        <li><h2>Connect your Osmo by USB-C</h2><p>Use a USB-C data cable and choose Webcam mode on the camera if prompted. Select the Osmo in Fieldrush Broadcaster, then check that the preview shows the whole pitch. Your Osmo model must support webcam mode.</p></li>
        <li><h2>Check the field sound</h2><p>Select the microphone carrying your camera or field audio. Speak near it and check that the audio meter moves. Keep the laptop speakers muted to prevent an echo. If the Osmo does not appear as an audio input, use a connected microphone and test it first.</p></li>
        <li><h2>Pair it with your match</h2><p>On your phone, sign in to Match day and select your assigned game. Open More → Camera and broadcast → Create pairing code. Enter that code in Fieldrush Broadcaster on the Mac. The code works once and expires after ten minutes.</p></li>
        <li><h2>Check recording, then go live</h2><p>Complete the readiness checks on the Mac, including camera, sound, recording space, and OBS connection. Start the stream from your phone and confirm that the video reaches the live player. Start the match clock separately at kickoff.</p></li>
        <li><h2>Finish and hand over</h2><p>Check that the stream has stopped and the recording has saved before closing the Mac. If the internet dropped, keep the complete local recording and use Recover recording in Fieldrush Broadcaster. Preview the uploaded video before choosing to replace the replay. Finish recovery before the 24-hour pairing expires or you disconnect the Mac. Then disconnect before handing it to the next referee.</p></li>
      </ol>
      <aside className={styles.guideNote}>A pairing belongs to one match and expires after 24 hours. Use a fresh code for the next match. Camera settings and local recordings remain on the Mac, so check the selected camera and microphone whenever using shared equipment.</aside>
    </main>
  );
}
