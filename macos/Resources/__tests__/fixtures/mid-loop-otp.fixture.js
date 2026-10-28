"use strict";

/**
 * The first phone submission is rejected, then the corrected +44
 * submission reveals an OTP challenge. Autofill must stop before a
 * third POST rather than trying to invent a verification code.
 */

const { createDocument } = require("./dom-shim");
const { el, labelFor, button } = require("./build-helpers");

function build() {
  const doc = createDocument();
  doc.title = "Guest WiFi";
  let submitCount = 0;

  const phoneInput = el(doc, "input", {
    type: "tel",
    id: "phone",
    name: "phone",
    required: "",
  });
  const errorText = el(doc, "p", { id: "phone-error" }, [""]);
  const submitBtn = button(doc, "Connect to WiFi", { type: "submit" });
  const form = el(doc, "form", {}, [
    labelFor(doc, "phone", "Mobile number"),
    phoneInput,
    errorText,
    submitBtn,
  ]);
  doc.body.appendChild(form);

  submitBtn.addEventListener("click", function () {
    submitCount += 1;
    if (submitCount === 1) {
      phoneInput.setAttribute("aria-invalid", "true");
      errorText.textContent =
        "Please include the country code, e.g. +44.";
      return;
    }

    doc.body.removeChild(form);
    const codeInput = el(doc, "input", {
      id: "code",
      name: "sms_code",
      inputmode: "numeric",
      maxlength: "6",
      required: "",
    });
    const verify = button(doc, "Verify", { type: "submit" });
    const otpForm = el(doc, "form", {}, [
      el(doc, "p", {}, [
        "Enter the verification code sent to your phone",
      ]),
      labelFor(doc, "code", "SMS code"),
      codeInput,
      verify,
    ]);
    verify.addEventListener("click", function () {
      submitCount += 1;
    });
    doc.body.appendChild(otpForm);
  });

  return {
    doc,
    identity: {phone: "07700900123"},
    getSubmitCount: function () {
      return submitCount;
    },
  };
}

module.exports = { build };
