"use strict";

/**
 * Value-free structural fixture from a Costa Meraki splash:
 * no <form>, an unnamed checkbox whose consent copy is a nearby sibling,
 * and an image-only grant <a> identified by its title.
 */

const { createDocument } = require("./dom-shim");
const { el } = require("./build-helpers");

function build() {
  const doc = createDocument();
  doc.title = "Costa Wifi - Wi-Fi terms and conditions";

  // Unrelated disclosure toggle above the long terms document. It must not
  // be treated as the acceptance checkbox.
  const disclosure = el(doc, "input", { type: "checkbox" });
  const longTerms = el(doc, "li", {}, [
    disclosure,
    "Terms of access to the Costa Wifi Service ".repeat(40),
  ]);

  const consent = el(doc, "input", { type: "checkbox" });
  const grant = el(
    doc,
    "a",
    {
      href: "/splash/fixture/grant?continue_url=https://www.costa.co.uk/connected",
      title: "Continue to the Internet",
    },
    [el(doc, "img", { alt: "Connect" })]
  );
  const label = el(doc, "label", { class: "check" }, [
    consent,
    el(doc, "div", { class: "expandable" }, [grant]),
  ]);
  const costaTerms = el(doc, "div", { class: "cos_terms" }, [
    el(doc, "div", { class: "box_container" }, [label]),
    el(doc, "div", { class: "Checkbox-Disclaimer" }, [
      "I agree to the terms and conditions of Costa Coffee Wi-fi.",
    ]),
  ]);

  doc.body.appendChild(el(doc, "ul", {}, [longTerms]));
  doc.body.appendChild(costaTerms);

  let accepted = false;
  grant.addEventListener("click", function (event) {
    event.preventDefault();
    accepted = consent.checked === true && disclosure.checked !== true;
    if (accepted) {
      doc.body.removeChild(costaTerms);
      doc.body.appendChild(el(doc, "div", {}, ["Connected"]));
    }
  });

  return {
    doc,
    identity: {},
    consent,
    disclosure,
    wasAccepted: () => accepted,
  };
}

module.exports = { build };
