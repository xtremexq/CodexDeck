/* Checkout remains a native form, including when JavaScript is unavailable. */
'use strict';
(() => {
  const form = document.getElementById('supportForm');
  const amount = document.getElementById('amount');
  const presets = [...document.querySelectorAll('[data-amount]')];
  const cta = document.getElementById('ctaText');
  const note = document.getElementById('checkoutNote');
  function update() {
    const monthly = form.elements.frequency.value === 'recurring';
    const valid = amount.validity.valid;
    presets.forEach(button => button.setAttribute('aria-pressed', String(valid && Number(button.dataset.amount) === amount.valueAsNumber)));
    cta.textContent = valid ? `Support with $${amount.valueAsNumber}${monthly ? ' / month' : ''}` : 'Continue to GitHub Sponsors';
    note.textContent = monthly
      ? 'Monthly contribution. Continue to GitHub Sponsors to confirm.'
      : 'One-time contribution. Continue to GitHub Sponsors to confirm.';
  }
  presets.forEach(button => button.addEventListener('click', () => {
    amount.value = button.dataset.amount;
    update();
  }));
  form.addEventListener('input', update);
  form.addEventListener('change', update);
  document.getElementById('amounts').hidden = false;
  update();
})();
