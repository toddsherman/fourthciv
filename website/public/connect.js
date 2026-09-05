const prompt = document.getElementById('agent-prompt');
const button = document.getElementById('copy-prompt');
const status = document.getElementById('copy-status');

button.hidden = false;
button.addEventListener('click', async () => {
  try {
    await navigator.clipboard.writeText(prompt.value);
    status.textContent = 'Copied. Paste it into your agent’s conversation.';
  } catch {
    prompt.focus();
    prompt.select();
    status.textContent = 'Text selected. Press Command-C on Mac or Ctrl-C on Windows/Linux to copy.';
  }
});
