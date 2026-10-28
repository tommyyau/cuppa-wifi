/**
 * WebView Autopilot — injected JS autofill script.
 * Runs in WebKit's isolated CuppaAutofill script world via
 * WKWebView.callAsyncJavaScript (see WebViewAutopilotController.swift),
 * which awaits the Promise `run()` returns and hands the resolved
 * {status, detail} object back to Swift directly (no JSON.stringify
 * needed — WebKit converts JS values that cross the bridge automatically).
 *
 * Structured as pure classification/formatting functions (classifyField,
 * isConsentLabel, isMarketingLabel, looksLikeSubmitControl,
 * detectFailClosed) plus a thin DOM-facing layer (effectiveLabel,
 * describeField, setNativeValue, run) so the pure half can be unit-tested
 * under plain Node (macos/Resources/__tests__/) without a real browser.
 *
 * Exported two ways:
 *   - CommonJS (`module.exports`) when running under Node for tests.
 *   - `window.__wifiAutologinAutofill` when injected into a real page.
 */
(function (root, factory) {
  var schema = root && root.__wifiAutologinSchema;
  var profiles = root && root.__wifiAutologinProfiles;
  if (typeof module !== "undefined" && module.exports) {
    schema = require("./portal-schema.json");
    profiles = require("./vendor-profiles.json");
  }
  var api = factory(schema, profiles);
  if (typeof module !== "undefined" && module.exports) {
    module.exports = api;
  }
  if (root) {
    root.__wifiAutologinAutofill = api;
  }
})(typeof window !== "undefined" ? window : typeof globalThis !== "undefined" ? globalThis : this, function (schema, profiles) {
  "use strict";

  function diagnosticStep(phase, title, detail, fields, status) {
    try {
      if (typeof window !== "undefined" && window.webkit && window.webkit.messageHandlers.diagnosticStep) {
        window.webkit.messageHandlers.diagnosticStep.postMessage({phase: phase, title: title, detail: detail || "", fields: fields || [], status: status || "ok"});
      }
    } catch (_) { /* Diagnostics must never interrupt sign-in. */ }
  }
  function diagnosticField(d, cls, category) {
    // Only metadata and a category cross the bridge; values never do.
    var evidence = classifyFieldEvidence(d);
    return {name: d.name || "", label: d.label || "", placeholder: d.placeholder || "", type: d.type || "",
      intent: evidence.intent || cls, source: evidence.evidence === "on_device" ? "Apple on-device model" : "JavaScript heuristic", category: category, maskedValue: category === "Skipped" ? "" : "[masked]"};
  }

  // ------------------------------------------------------------------
  // Step 2: fail-closed detection. Mirrors handlers/generic.py's
  // _VERIFICATION_RE / _CAPTCHA_RE / _VOUCHER_RE family so the WebView
  // path surrenders on exactly the same portals the static engine does.
  // ------------------------------------------------------------------
  var FAIL_CLOSED_PATTERNS = [
    { reason: "verification_code_required", re: /\b(otp|one[-\s]?time\s*(password|pass\s*code|code)?|verification\s*code|sms\s*code|passcode|security\s*code|access\s*code)\b/i },
    { reason: "captcha_required", re: /\bcaptcha\b/i },
    { reason: "voucher_or_venue_credential_required", re: /\b(voucher|payment|card\s*number|credit\s*card|debit\s*card)\b/i },
  ];

  function detectFailClosed(pageText) {
    var text = pageText || "";
    for (var i = 0; i < FAIL_CLOSED_PATTERNS.length; i++) {
      if (FAIL_CLOSED_PATTERNS[i].re.test(text)) {
        return FAIL_CLOSED_PATTERNS[i].reason;
      }
    }
    return null;
  }

  function detectVenue(pageText, title) {
    var text = [pageText || "", title || ""].join(" ");
    if (/\bpret(?:\s+a\s+manger)?\b/i.test(text)) return "Pret";
    return null;
  }


  var LEGACY_INTENTS = { first_name: "firstName", last_name: "lastName", full_name: "fullName",
    address_line_1: "address", address_line_2: "addressLine2", date_of_birth: "dob",
    reason_for_visit: "reasonForVisit", customer_status: "customerStatus" };
  var reasonedFields = new WeakMap();
  var appliedValues = new WeakMap();
  var widgetSelections = new WeakMap();
  var widgetAttempts = new WeakMap();
  var classificationAttempts = new WeakMap();
  var phoneIdentities = new WeakMap();
  var authorizedCredentials = new WeakMap();
  var submittedSignup = new WeakSet();
  var correctionStates = new WeakMap();

  function correctionKey(el,doc) {
    var d=describeField(el,doc), cls=classifyField(d);
    return ['phone','postcode','dob'].indexOf(cls) >= 0 ? cls+':'+(d.name || d.id || d.label) : null;
  }
  function rememberCorrections(doc,scope,publish) {
    var state=correctionStates.get(doc) || {};
    for(var el of correctableFields(scope)) {
      var key=correctionKey(el,doc), value=String(el.value || '');
      if(!key || !value)continue;
      var tried=state[key] || [];
      if(tried.indexOf(value)<0)tried.push(value);
      state[key]=tried.slice(-4);
    }
    correctionStates.set(doc,state);
    if(publish)publish(state);
    try{if(window.webkit && window.webkit.messageHandlers.portalCorrections)window.webkit.messageHandlers.portalCorrections.postMessage(state)}catch(_){}
  }

  function classifyFieldEvidence(d, profile) {
    d = d || {};
    if (!schema || schema.version !== 1) return { intent: null, confidence: 0, evidence: "missing_rules" };
    if (issuedIdentifier(d)) return {intent:'issued_identifier',confidence:1,evidence:'policy'};
    var tokens = (d.autocomplete || "").toLowerCase().split(/\s+/);
    var autocompleteIntent = null;
    for (var i = tokens.length - 1; i >= 0; i--) {
      if (schema.autocomplete[tokens[i]]) { autocompleteIntent = schema.autocomplete[tokens[i]]; break; }
    }
    var type = (d.type || "").toLowerCase();
    var specificIntent = ["verification_code", "account_password", "phone_country_code"].indexOf(autocompleteIntent) !== -1;
    if (schema.types[type] && !specificIntent) return { intent: schema.types[type], confidence: 1, evidence: "type" };
    if (autocompleteIntent) return {intent: autocompleteIntent, confidence: 1, evidence: "autocomplete"};
    if (d.reasonedIntent) return {intent: d.reasonedIntent, confidence: .85, evidence: "on_device"};
    var localText=[d.name,d.id,d.label,d.placeholder,d.ariaLabel,d.description].filter(Boolean).join(' ');
    var countryIdentifiers=[d.name,d.id].filter(Boolean).join(' ').replace(/([a-z0-9])([A-Z])/g,'$1 $2').replace(/[_-]+/g,' ');
    var matches=new Set(schema.patterns.filter(function(r){return new RegExp(r.pattern,'i').test(localText+(r.intent === 'country' ? ' '+countryIdentifiers : ''))}).map(function(r){return r.intent}));
    var birthGroup=schema.patterns.some(function(r){return r.intent === 'date_of_birth' && new RegExp(r.pattern,'i').test(d.fieldset || '')});
    if(birthGroup) {
      var components=['day','month','year'].filter(function(part){return new RegExp('\\b'+part+'\\b','i').test(localText)});
      if(components.length === 1)return {intent:'birth_'+components[0],confidence:.95,evidence:'group_component'};
    }
    if((matches.has('first_name') && matches.has('last_name')) || (schema.compoundName && new RegExp(schema.compoundName,'i').test(localText))) {
      matches.delete('first_name');matches.delete('last_name');matches.add('full_name');
    } else if(matches.has('first_name') || matches.has('last_name'))matches.delete('full_name');
    for(var pair of [['email','address_line_1'],['address_line_2','address_line_1'],['occupation','title'],['postcode','address_line_1'],['phone_country_code','country'],['phone_country_code','phone']])if(matches.has(pair[0]))matches.delete(pair[1]);
    if(['birth_day','birth_month','birth_year'].some(function(i){return matches.has(i)}))matches.delete('date_of_birth');
    var weakDescription=new Set();
    for(var candidate of matches) {
      var ambiguity=(schema.descriptionAmbiguity || {})[candidate];
      var primary=[d.name,d.id,d.label,d.placeholder,d.ariaLabel].filter(Boolean).join(' ');
      if(ambiguity && new RegExp(ambiguity.wording,'i').test(d.description || '')
          && !new RegExp(ambiguity.wording,'i').test(primary)
          && !new RegExp(ambiguity.specific,'i').test(localText))weakDescription.add(candidate);
    }
    weakDescription.forEach(function(intent){matches.delete(intent)});
    for (var key of ["name", "id"]) {
      var name = String(d[key] || "").toLowerCase().replace(/[^a-z0-9]/g, "");
      if (profile && profile.fieldAliases && profile.fieldAliases[name]) return {intent: profile.fieldAliases[name], confidence: .95, evidence: "provider_alias"};
      if (schema.names[name]) {
        if (numericMeaningConflict(type,schema.names[name])) return {intent:null,confidence:.35,evidence:'conflict',candidates:[schema.names[name]]};
        if(matches.size > 1 || (matches.size && !matches.has(schema.names[name]) && !(matches.size === 1 && matches.has('full_name'))))return {intent:null,confidence:.35,evidence:'conflict',candidates:Array.from(new Set(Array.from(matches).concat([schema.names[name]]))).sort()};
        return { intent: schema.names[name], confidence: .95, evidence: "identifier" };
      }
    }
    if(matches.size === 1) {
      var meaning=Array.from(matches)[0];
      if(numericMeaningConflict(type,meaning))return {intent:null,confidence:.35,evidence:'conflict',candidates:[meaning]};
      return {intent:meaning,confidence:.85,evidence:'wording'};
    }
    if(matches.size)return {intent:null,confidence:.35,evidence:'conflict',candidates:Array.from(matches).sort()};
    if(weakDescription.size)return {intent:null,confidence:.35,evidence:'conflict',candidates:Array.from(weakDescription).sort()};
    return { intent: null, confidence: 0, evidence: "unresolved" };
  }

  function numericMeaningConflict(type,intent) {
    return type === 'number' && ((schema.reasoning || {}).numericTextIntents || []).indexOf(intent)>=0;
  }

  function classifyField(d, profile) {
    var intent = classifyFieldEvidence(d, profile).intent;
    return LEGACY_INTENTS[intent] || intent || "unknown";
  }

  function providerFor(doc) {
    var host = ((doc.location && doc.location.hostname) || "").toLowerCase();
    return ((profiles && profiles.profiles) || []).find(function (profile) {
      return profile.hosts.some(function (domain) { return host === domain || host.endsWith("." + domain); });
    }) || { id: "generic", actionHints: [], fieldAliases: {} };
  }

  function valueForClassification(cls, identity) {
    identity = identity || {};
    switch (cls) {
      case "email": return identity.email || null;
      case "phone": return identity.phone || null;
      case "firstName": return identity.firstName || null;
      case "lastName": return identity.lastName || null;
      case "fullName":
        return [identity.firstName, identity.lastName].filter(Boolean).join(" ") || null;
      case "postcode": return identity.postcode || null;
      case "address": return identity.address || identity.addressLine1 || null;
      case "addressLine2": return identity.addressLine2 || null;
      case "city": return identity.city || null;
      case "county": return identity.county || null;
      case "country": return identity.country || null;
      case "gender": return identity.gender || null;
      case "title": return identity.title || null;
      case "dob": return identity.dob || identity.dateOfBirth || null;
      case "age": return ageFromDob(identity.dob || identity.dateOfBirth);
      case "company": return identity.company || null;
      case "occupation": return identity.occupation || null;
      case "reasonForVisit": return identity.reasonForVisit || null;
      case "customerStatus": return "No";
      case "password": return identity.password || null;
      case "username": return identity.email || null;
      case "phone_country_code": return /^(united kingdom|uk|gb)$/i.test(identity.country || "") || /^\+44/.test(identity.phone || "") ? "+44" : null;
      case "birth_day": return /^\d{4}-\d{2}-\d{2}$/.test(identity.dob || "") ? String(parseInt(identity.dob.split("-")[2], 10)) : null;
      case "birth_month": return /^\d{4}-\d{2}-\d{2}$/.test(identity.dob || "") ? String(parseInt(identity.dob.split("-")[1], 10)) : null;
      case "birth_year": return /^\d{4}-\d{2}-\d{2}$/.test(identity.dob || "") ? identity.dob.split("-")[0] : null;
      default: return null;
    }
  }

  function ageFromDob(value) {
    var match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value || "");
    if (!match) return null;
    var today = new Date();
    var age = today.getFullYear() - parseInt(match[1], 10);
    var month = today.getMonth() + 1;
    var day = today.getDate();
    if (
      month < parseInt(match[2], 10)
      || (
        month === parseInt(match[2], 10)
        && day < parseInt(match[3], 10)
      )
    ) {
      age -= 1;
    }
    return String(age);
  }

  // ------------------------------------------------------------------
  // Step 5: consent checkboxes. Marketing is checked FIRST and always
  // wins — a label matching both (e.g. "I agree to receive marketing
  // offers") must never be ticked.
  // ------------------------------------------------------------------
  var MARKETING_RE = /marketing|offers?\b|newsletter|promo/i;
  var CONSENT_RE = /terms|conditions|t&c|t and c|(?:^|[\s_-])tnc(?:$|[\s_-])|privacy|\bagree\b|accept/i;

  function isMarketingLabel(label) {
    return new RegExp(schema ? schema.consent.marketing : MARKETING_RE.source, "i").test(label || "") || /opt[ _-]*out/i.test(label || "");
  }
  function isOptOutLabel(label) {
    return isMarketingLabel(label) && new RegExp(schema ? schema.consent.optOut : "opt.?out|do not|decline", "i").test(label || "");
  }

  function isConsentLabel(label) {
    if (isMarketingLabel(label)) return false;
    return new RegExp(schema ? schema.consent.terms : CONSENT_RE.source, "i").test(label || "");
  }

  // Cookie overlays are not portal consent. When an explicit privacy-safe
  // rejection is available, dismiss it before interacting with the actual
  // Wi-Fi form. Never fall back to "Accept all".
  var COOKIE_REJECT_RE = /reject\s+all\s+cookies|reject\s+(?:all\s+)?optional|decline\s+all\s+cookies|(?:use|allow|keep)\s+(?:only\s+)?necessary\s+cookies|necessary\s+cookies\s+only|continue\s+without\s+accepting/i;

  function looksLikeCookieRejectControl(c) {
    c = c || {};
    return COOKIE_REJECT_RE.test(
      [c.text, c.ariaLabel, c.title].filter(Boolean).join(" ")
    );
  }

  // ------------------------------------------------------------------
  // Step 7: submit control scoring.
  // ------------------------------------------------------------------
  var SUBMIT_TEXT_RE = /connect|continue|accept|get\s*online|free\s*wifi|log\s*?in|sign\s*?(?:in|up)|register|submit|next|join/i;
  var NEGATIVE_SUBMIT_RE = /cancel|back|no\s*thanks|decline|skip/i;

  function looksLikeSubmitControl(c) {
    // c: {tagName, type, text, ariaLabel, title}
    c = c || {};
    var tagName = (c.tagName || "").toUpperCase();
    var type = (c.type || "").toLowerCase();
    var descriptor = [c.text, c.ariaLabel, c.title]
      .filter(Boolean)
      .join(" ")
      .trim();
    if (NEGATIVE_SUBMIT_RE.test(descriptor)) return false;
    if (type === "submit") return true;
    if (
      (tagName === "BUTTON"
        || tagName === "INPUT"
        || tagName === "A"
        || (c.role || "").toLowerCase() === "button")
      && SUBMIT_TEXT_RE.test(descriptor)
    ) return true;
    return false;
  }

  // ------------------------------------------------------------------
  // Step 8: feedback-retry loop — correction-generator functions.
  // Follow the shared correction-ladder.json format order.
  // Each takes the value that was just
  // rejected and returns an ORDERED list of next candidates to try
  // (already-tried/equal-to-input values are excluded by the caller
  // walking the list, not by these functions knowing history).
  // ------------------------------------------------------------------

  // Rejection copy a portal shows after a failed submit.
  var REJECTION_TEXT_RE = /invalid|not valid|required|please (enter|provide|correct|fill)|must (be|include|contain|start)|incorrect|too (short|long)|enter a valid|country code|include the area code|enter (international|national)|omit (the )?(first|leading) 0/i;

  var ERROR_CLASS_RE = /(^|\s)(error|is-invalid|has-error)(\s|$)/i;

  var DEFAULT_CORRECTION_LADDER = {
    format: 1,
    maxCorrectionRounds: 3,
    phoneFormats: ["national", "e164", "international_00", "digits"],
    postcodeFormats: ["spaced_upper", "compact_upper", "upper", "compact"],
    dateFormats: ["yyyy-mm-dd", "dd/mm/yyyy", "mm/dd/yyyy", "dd-mm-yyyy"],
  };
  var correctionLadder = DEFAULT_CORRECTION_LADDER;

  function configureCorrectionLadder(candidate) {
    if (
      !candidate
      || candidate.format !== 1
      || typeof candidate.maxCorrectionRounds !== "number"
      || candidate.maxCorrectionRounds < 0
      || candidate.maxCorrectionRounds > 5
    ) {
      correctionLadder = DEFAULT_CORRECTION_LADDER;
      return correctionLadder;
    }
    var arrayKeys = [
      "phoneFormats",
      "postcodeFormats",
      "dateFormats",
    ];
    for (var i = 0; i < arrayKeys.length; i++) {
      if (!Array.isArray(candidate[arrayKeys[i]])) {
        correctionLadder = DEFAULT_CORRECTION_LADDER;
        return correctionLadder;
      }
    }
    correctionLadder = candidate;
    return correctionLadder;
  }

  function phoneVariants(value) {
    var raw = String(value == null ? "" : value);
    var digits = raw.replace(/\D/g, "");
    var national = digits;
    if (national.indexOf("0044") === 0) {
      national = national.slice(4);
    } else if (national.indexOf("44") === 0 && national.length > 10) {
      national = national.slice(2);
    } else if (national.indexOf("0") === 0) {
      national = national.slice(1);
    }
    if (!national) return [];
    var national0 = "0" + national;
    var intlPlus = "+44" + national;
    var intl00 = "0044" + national;
    var stripped = raw.replace(/[\s().-]/g, "");
    var formats = {
      national: national0,
      e164: intlPlus,
      international_00: intl00,
      digits: stripped,
    };
    var ordered = correctionLadder.phoneFormats.map(function (name) {
      return formats[name];
    });
    var seen = {};
    var out = [];
    for (var i = 0; i < ordered.length; i++) {
      var v = ordered[i];
      if (v && v !== raw && !seen[v]) {
        seen[v] = true;
        out.push(v);
      }
    }
    return out;
  }

  function postcodeVariants(value) {
    var raw = String(value == null ? "" : value).trim();
    if (!raw) return [];
    var compact = raw.replace(/\s+/g, "").toUpperCase();
    var spaced = compact.length >= 5
      ? compact.slice(0, compact.length - 3) + " " + compact.slice(-3)
      : compact;
    var formats = {
      spaced_upper: spaced,
      compact_upper: compact,
      upper: raw.toUpperCase(),
      compact: raw.replace(/\s+/g, ""),
    };
    var ordered = correctionLadder.postcodeFormats.map(function (name) {
      return formats[name];
    });
    var seen = {};
    var out = [];
    for (var i = 0; i < ordered.length; i++) {
      var v = ordered[i];
      if (v && v !== raw && !seen[v]) {
        seen[v] = true;
        out.push(v);
      }
    }
    return out;
  }

  function pad2(n) {
    var s = String(n);
    return s.length < 2 ? "0" + s : s;
  }

  // Best-effort flexible parse of the formats we ourselves round-trip
  // through. Ambiguous d/m vs m/d pairs (both <=12) default to UK
  // day-first, matching the rest of this file's UK-first assumptions.
  function parseFlexibleDate(value) {
    var s = String(value == null ? "" : value).trim();
    var m = /^(\d{4})-(\d{1,2})-(\d{1,2})$/.exec(s);
    if (m) return { y: m[1], m: m[2], d: m[3] };
    m = /^(\d{1,2})\/(\d{1,2})\/(\d{4})$/.exec(s);
    if (m) return resolveAmbiguousDmy(m[1], m[2], m[3]);
    m = /^(\d{1,2})-(\d{1,2})-(\d{4})$/.exec(s);
    if (m) return resolveAmbiguousDmy(m[1], m[2], m[3]);
    return null;
  }

  function resolveAmbiguousDmy(a, b, y) {
    var an = parseInt(a, 10);
    var bn = parseInt(b, 10);
    if (an > 12) return { y: y, m: b, d: a };
    if (bn > 12) return { y: y, m: a, d: b };
    return { y: y, m: a, d: b }; // ambiguous: assume day-first (UK)
  }

  function formatDate(parts, fmt) {
    var y = parts.y, mo = pad2(parts.m), d = pad2(parts.d);
    switch (fmt) {
      case "yyyy-mm-dd": return y + "-" + mo + "-" + d;
      case "dd/mm/yyyy": return d + "/" + mo + "/" + y;
      case "mm/dd/yyyy": return mo + "/" + d + "/" + y;
      case "dd-mm-yyyy": return d + "-" + mo + "-" + y;
      default: return y + "-" + mo + "-" + d;
    }
  }

  function dateVariants(value) {
    var parts = parseFlexibleDate(value);
    if (!parts) return [];
    var raw = String(value == null ? "" : value);
    var seen = {};
    var out = [];
    for (var i = 0; i < correctionLadder.dateFormats.length; i++) {
      var v = formatDate(parts, correctionLadder.dateFormats[i]);
      if (v && v !== raw && !seen[v]) {
        seen[v] = true;
        out.push(v);
      }
    }
    return out;
  }

  // Rejection does not permit changing an email address. Report it so the
  // user can choose a different address deliberately.
  function emailVariants(_value) {
    return [];
  }

  // ==================================================================
  // DOM-facing layer below. Everything above this line is pure and
  // covered directly by macos/Resources/__tests__/autofill.test.js.
  // ==================================================================

  function textOf(node) {
    if (!node) return "";
    if (typeof node.innerText === "string") return node.innerText;
    if (typeof node.textContent === "string") return node.textContent;
    return "";
  }

  function isVisible(el) {
    if (!el) return false;
    if (el.getAttribute && el.getAttribute("type") === "hidden") return false;
    var original = el;
    while (el && el.nodeType !== 9) {
      if (el.hidden || el.inert || (el.getAttribute && el.getAttribute("aria-hidden") === "true")) return false;
      var style = (el.getAttribute && el.getAttribute("style")) || "";
      if (/display\s*:\s*none|visibility\s*:\s*hidden/i.test(style)) return false;
      var view = el.ownerDocument && el.ownerDocument.defaultView;
      if (view && view.getComputedStyle && el.nodeType === 1) {
        var computed = view.getComputedStyle(el);
        if (computed.display === "none" || computed.visibility === "hidden" || computed.visibility === "collapse") return false;
      }
      var parent = el.parentElement;
      if (!parent && el.getRootNode) parent = el.getRootNode().host;
      el = parent;
    }
    var owner = original.ownerDocument;
    try { if (owner && owner.defaultView && owner.defaultView.frameElement && !isVisible(owner.defaultView.frameElement)) return false; } catch (_) {}
    return true;
  }

  function isEnabled(el) {
    if (el.disabled || (el.getAttribute && el.getAttribute("aria-disabled") === "true")) return false;
    var node = el.parentElement;
    while (node) {
      if (node.inert || (node.tagName === "FIELDSET" && node.disabled)) return false;
      node = node.parentElement;
    }
    return true;
  }

  function findLabelFor(id, doc) {
    if (!id) return null;
    var labels = doc.querySelectorAll("label");
    for (var i = 0; i < labels.length; i++) {
      if (labels[i].getAttribute("for") === id) return labels[i];
    }
    return null;
  }

  function closestLabel(el) {
    var node = el.parentElement;
    while (node) {
      if ((node.tagName || "").toUpperCase() === "LABEL") return node;
      node = node.parentElement;
    }
    return null;
  }

  function adjacentText(el) {
    // Best-effort: text of the immediately preceding sibling, whether a
    // text node or an element (e.g. <span>Postcode</span><input>).
    var sib = el.previousSibling;
    while (sib) {
      var text = textOf(sib).trim();
      if (text) return text;
      sib = sib.previousSibling;
    }
    return null;
  }

  function effectiveLabel(el, doc) {
    doc = el.getRootNode ? el.getRootNode() : doc || el.ownerDocument;
    if (!doc.getElementById) doc = el.ownerDocument;
    var byFor = el.id ? findLabelFor(el.id, doc) : null;
    if (byFor && textOf(byFor).trim()) return textOf(byFor).trim();

    var wrapping = closestLabel(el);
    if (wrapping && textOf(wrapping).trim()) return textOf(wrapping).trim();

    var ariaLabel = el.getAttribute("aria-label");
    if (ariaLabel && ariaLabel.trim()) return ariaLabel.trim();

    var labelledBy = el.getAttribute("aria-labelledby");
    if (labelledBy) {
      var parts = labelledBy
        .split(/\s+/)
        .map(function (id) {
          var t = doc.getElementById(id);
          return t ? textOf(t).trim() : "";
        })
        .filter(Boolean);
      if (parts.length) return parts.join(" ");
    }

    var placeholder = el.getAttribute("placeholder");
    if (placeholder && placeholder.trim()) return placeholder.trim();

    var adjacent = adjacentText(el);
    if (adjacent) return adjacent;

    return el.getAttribute("name") || el.id || "";
  }

  function contextualCheckboxLabel(el) {
    // Costa's real consent text is a sibling of an unnamed checkbox three
    // wrappers up, while the checkbox's own <label> contains only the grant
    // image/link. Search a small bounded ancestor context only when the normal
    // label is empty. A large terms-document accordion is deliberately
    // ignored so its disclosure toggle is not mistaken for consent.
    var node = el.parentElement;
    for (var depth = 0; node && depth < 4; depth++, node = node.parentElement) {
      var text = textOf(node).replace(/\s+/g, " ").trim();
      if (
        text
        && text.length <= 600
        && (isConsentLabel(text) || isMarketingLabel(text))
      ) {
        return text;
      }
    }
    return "";
  }

  function describeField(el, doc) {
    doc = el.ownerDocument || doc;
    var role = el.getAttribute("role") || "";
    var type = (role === "combobox" ? "select" : role === "checkbox" || role === "radio" ? role : el.getAttribute("type") || (el.tagName === "TEXTAREA" ? "textarea" : el.tagName === "SELECT" ? "select" : "text")).toLowerCase();
    var fieldset = el.closest ? el.closest("fieldset,[role=\"radiogroup\"]") : null;
    var root = el.getRootNode ? el.getRootNode() : doc;
    if (!root.getElementById) root = doc;
    var described = (el.getAttribute("aria-describedby") || "").split(/\s+/).filter(Boolean).map(function (id) { return textOf(root.getElementById(id) || doc.getElementById(id)); }).join(" ");
    var result = {
      label: effectiveLabel(el, doc), placeholder: el.getAttribute("placeholder") || "",
      name: el.getAttribute("name") || "", id: el.id || "", ariaLabel: el.getAttribute("aria-label") || "",
      description: described, fieldset: fieldset ? (fieldset.getAttribute("aria-label") || textOf(fieldset.querySelector("legend"))) : "",
      autocomplete: el.getAttribute("autocomplete") || "", type: type, required: descriptorRequired(el),
      minLength: parseInt(el.getAttribute("minlength"), 10) || null,
      maxLength: parseInt(el.getAttribute("maxlength"), 10) || null,
      pattern: el.getAttribute("pattern") || null, min: el.getAttribute("min"), max: el.getAttribute("max"),
      inputmode: el.getAttribute("inputmode") || "",
    };
    var cached = reasonedFields.get(el);
    if (cached && cached.shape === fieldShape(result)) result.reasonedIntent = cached.intent;
    return result;
  }

  function fieldShape(d) { return JSON.stringify([d.name,d.id,d.label,d.type,d.autocomplete,d.fieldset,d.description,d.required]); }

  function issuedIdentifier(d) {
    return !!(schema.policy && new RegExp(schema.policy.issuedIdentifier,'i').test([d.name,d.id,d.label,d.description,d.placeholder,d.ariaLabel].join(' ')));
  }
  function socialAction(el) {
    if(!schema.policy)return false;
    if(new RegExp(schema.policy.socialAction,'i').test([textOf(el),el.value,el.getAttribute('aria-label')].join(' ')))return true;
    var url=el.getAttribute('href') || el.getAttribute('formaction') || '';
    for(var i=0;i<3;i++){
      if(new RegExp(schema.policy.socialDestination,'i').test(url))return true;
      try{url=decodeURIComponent(url)}catch(_){break}
    }
    return false;
  }

  function nativeSetterFor(el) {
    var tag = (el.tagName || "").toUpperCase();
    var w = el.ownerDocument && el.ownerDocument.defaultView;
    var constructor = w && (tag === "TEXTAREA" ? w.HTMLTextAreaElement : tag === "SELECT" ? w.HTMLSelectElement : tag === "INPUT" ? w.HTMLInputElement : null);
    var descriptor = constructor && Object.getOwnPropertyDescriptor(constructor.prototype, "value");
    return descriptor && descriptor.set;
  }

  function fireEvent(el, type) {
    var EventCtor = (el.ownerDocument && el.ownerDocument.defaultView && el.ownerDocument.defaultView.Event) || (typeof Event !== "undefined" ? Event : null);
    if (!EventCtor) return;
    el.dispatchEvent(new EventCtor(type, { bubbles: true }));
  }

  function setNativeValue(el, value) {
    if (appliedValues.get(el) === String(value) && String(el.value) === String(value)) return;
    var setter = nativeSetterFor(el);
    if (setter) {
      setter.call(el, value);
    } else {
      el.value = value;
    }
    fireEvent(el, "input");
    fireEvent(el, "change");
    fireEvent(el, "blur");
    appliedValues.set(el, String(value));
  }

  function setNativeChecked(el, checked) {
    if (!!el.checked === checked) return;
    if (typeof el.click === "function") el.click();
    if (!!el.checked !== checked) { el.checked = checked; fireEvent(el, "input"); fireEvent(el, "change"); }
  }

  function deepQuery(scope, selector, depth) {
    depth = depth || 0;
    if (!scope || !scope.querySelectorAll || depth > 4) return [];
    var found = toArray(scope.querySelectorAll(selector));
    var nodes = toArray(scope.querySelectorAll("*"));
    for (var node of nodes) {
      if (!isVisible(node)) continue;
      if (node.shadowRoot) found = found.concat(deepQuery(node.shadowRoot, selector, depth + 1));
      if (node.tagName === "IFRAME") {
        try { if (node.contentDocument) found = found.concat(deepQuery(node.contentDocument, selector, depth + 1)); } catch (_) {}
      }
    }
    return found.filter(function (el, i, all) { return all.indexOf(el) === i; });
  }

  function collectFormFields(formEl) {
    var found = deepQuery(formEl, "input, select, textarea, [role=\"checkbox\"], [role=\"radio\"], [role=\"combobox\"]");
    if (formEl.elements) found = found.concat(toArray(formEl.elements));
    return found.filter(function (el, i, all) { var custom=/^(checkbox|radio|combobox)$/.test(el.getAttribute('role') || ''); return all.indexOf(el) === i && (custom || ['INPUT','SELECT','TEXTAREA'].indexOf(el.tagName) >= 0) && (custom || !/^(hidden|submit|button|reset|image)$/.test(el.getAttribute('type') || '')); });
  }

  function consentFor(el, doc) {
    var descriptor = describeField(el, doc);
    var label = descriptor.label + " " + descriptor.fieldset, cls = classifyField(descriptor);
    if (cls === 'unknown' && !isConsentLabel(label) && !isMarketingLabel(label)) {
      label += " " + contextualCheckboxLabel(el);
    }
    if (isMarketingLabel(label) || cls === 'marketing_opt_in' || cls === 'marketing_opt_out') return isOptOutLabel(label) || cls === 'marketing_opt_out' ? 'marketing_opt_out' : 'marketing_opt_in';
    return isConsentLabel(label) || cls === 'terms' ? 'terms' : 'unknown';
  }

  function toArray(nodeList) {
    var out = [];
    for (var i = 0; i < nodeList.length; i++) out.push(nodeList[i]);
    return out;
  }

  function findForms(doc) { return deepQuery(doc, "form"); }

  function isSearchForm(form) {
    var fields=collectFormFields(form).filter(function(el){return isVisible(el) && isEnabled(el) && !/^(hidden|submit|button|reset|image)$/.test(el.type || '')});
    return form.getAttribute('role') === 'search' || (fields.length > 0 && fields.every(function(el){return el.type === 'search'}));
  }

  function unavailablePortalPage(doc) {
    if (/^\s*(404\b|410\b|page not found\b|not found\b|service unavailable\b|site unavailable\b)/i.test(doc.title || '')) return true;
    var forms=findForms(doc).filter(isVisible);
    return forms.length > 0 && forms.every(isSearchForm) && !actionControls(doc.body || doc).some(function(el){
      if (el.form && forms.indexOf(el.form) >= 0) return false;
      for(var parent=el.parentNode;parent;parent=parent.parentNode)if(forms.indexOf(parent)>=0)return false;
      return isVisible(el) && isEnabled(el) && /\b(connect|get online|activate access|start browsing)\b/i.test(textOf(el) || el.value || '');
    });
  }

  function chooseForm(doc) {
    var forms = findForms(doc);
    var best = null;
    var bestScore = -1;
    for (var i = 0; i < forms.length; i++) {
      var form = forms[i];
      if (!isVisible(form) || isSearchForm(form)) continue;
      var fields = collectFormFields(form).filter(function (field) {
        return isVisible(field) && isEnabled(field);
      });
      var score = fields.length;
      if (workflowGate(doc, form)) score -= 100;
      for (var j = 0; j < fields.length; j++) {
        if (descriptorRequired(fields[j])) score += 2;
        if (classifyField(describeField(fields[j], doc)) !== "unknown") {
          score += 2;
        }
      }
      if (findSubmitCandidate(form)) score += 4;
      if (score === 0) continue;
      if (score > bestScore) {
        best = form;
        bestScore = score;
      }
    }
    return best;
  }

  function actionControls(scope) {
    var candidates=deepQuery(scope,'button,input[type="submit"],input[type="button"],a,[role="button"]');
    if(scope.elements)candidates=candidates.concat(toArray(scope.elements).filter(function(el){return el.tagName === 'BUTTON' || /^(submit|button)$/.test(el.type || '')}));
    return candidates.filter(function(el,i,all){return all.indexOf(el) === i});
  }

  function actionScore(el) {
    var owner=el.form || (el.closest && el.closest('form'));
    if (owner && isSearchForm(owner)) return -100;
    if (socialAction(el)) return -100;
    var text = [textOf(el) || el.value || "", el.getAttribute("aria-label") || "", el.getAttribute("title") || ""].join(" ").trim();
    if (/cancel|\bback\b|\bclose\b|forgot|reset password|accept all cookies|buy|pay|premium|upgrade|continue with (?:google|facebook|apple)/i.test(text)) return -100;
    if (isMarketingLabel(text)) return /no thanks|decline|skip|opt.?out/i.test(text) ? 30 : -100;
    if (NEGATIVE_SUBMIT_RE.test(text)) return -100;
    var type = (el.getAttribute("type") || "").toLowerCase();
    var score = /guest|free\s*(?:wi.?fi|access)|use (?:your )?email|without.*account/i.test(text) ? 30 : 0;
    if (/get online|connect|activate|start browsing/i.test(text)) score += 25;
    if (/continue|next|accept|join|sign\s*up|register|create.*account/i.test(text)) score += 15;
    if (/log\s*in|sign\s*in/i.test(text)) score += 5;
    if (type === "submit" || (el.tagName === "BUTTON" && !type)) score += 4;
    if (!score) return -100;
    var profile = providerFor(el.ownerDocument || {});
    for (var hint of profile.actionHints || []) if (text.toLowerCase().includes(hint)) score += 2;
    return score;
  }

  function findSubmitCandidates(scopeEl) {
    var candidates = actionControls(scopeEl);
    return candidates.filter(function (el) { return isVisible(el) && isEnabled(el) && actionScore(el) > 0; })
      .sort(function (a, b) { return actionScore(b) - actionScore(a); });
  }

  function findSubmitCandidate(scopeEl) {
    var all = findSubmitCandidates(scopeEl);
    return all.length ? all[0] : null;
  }

  function dismissCookieBanner(doc) {
    var candidates = toArray(
      doc.querySelectorAll(
        "button, input[type=\"button\"], input[type=\"submit\"], "
          + "a, [role=\"button\"]"
      )
    );
    for (var i = 0; i < candidates.length; i++) {
      var el = candidates[i];
      if (!isVisible(el) || !isEnabled(el)) continue;
      if (
        looksLikeCookieRejectControl({
          text: textOf(el) || el.value || "",
          ariaLabel: el.getAttribute("aria-label") || "",
          title: el.getAttribute("title") || "",
        })
      ) {
        el.click();
        return true;
      }
    }
    return false;
  }


  function accountFormKind(doc, scope) {
    if (!scope) return null;
    var passwords=collectFormFields(scope).filter(function(el){return isVisible(el) && isEnabled(el) && (el.getAttribute('type') || '').toLowerCase() === 'password'});
    if (!passwords.length) return null;
    var formText=[scope.getAttribute('action'),scope.id,scope.getAttribute('name')].join(' ');
    var actions=actionControls(scope).filter(function(el){return isVisible(el) && isEnabled(el)}).map(function(el){return textOf(el) || el.value || ''}).join(' ');
    if (/signup|sign[ _-]*up|register|create.*account|new.*account/i.test(formText+' '+actions)
        || passwords.some(function(el){return (el.getAttribute('autocomplete') || '').split(/\s+/).includes('new-password')})) return 'create';
    if (/login|log[ _-]*in|sign[ _-]*in/i.test(formText+' '+actions)
        || passwords.some(function(el){return descriptorRequired(el) && (el.getAttribute('autocomplete') || '').split(/\s+/).includes('current-password')})) return 'existing';
    return null;
  }

  function workflowGate(doc, scope) {
    scope = scope || chooseForm(doc) || doc.body || doc;
    var fields = collectFormFields(scope).filter(function (el) { return isVisible(el) && isEnabled(el); });
    var visibleText=textOf(doc.body || doc);
    var credentials=authorizedCredentials.get(doc);
    var accountKind=accountFormKind(doc,scope);
    if (accountKind === 'existing' && !credentials) return 'account_credentials_required';
    if (accountKind === 'create' && credentials && credentials.operation !== 'create') return 'account_credentials_required';
    var freeBranch=findSubmitCandidates(doc.body || doc).some(function(el){return /guest|free|sign\s*up|register|create.*account/i.test(textOf(el) || el.value || '')});
    if(!freeBranch && fields.some(function(el){return /^cc-/.test(el.getAttribute('autocomplete') || '')}))return 'payment_required';
    if(!fields.length && /e[-\s]?mail|inbox/i.test(visibleText) && /verif|confirm|activat/i.test(visibleText) && /link|inbox|click|sent/i.test(visibleText))return 'email_verification';
    var ordinary = fields.some(function (el) { return /^(email|firstName|lastName|fullName|postcode|phone)$/.test(classifyField(describeField(el, doc))); });
    for (var el of fields) {
      var d = describeField(el, doc);
      if (!d.required && fields.length > 1) continue;
      var text = [d.name, d.id, d.label, d.autocomplete, d.description, d.fieldset].join(" ").normalize('NFD').replace(/[\u0300-\u036f]/g,'');
      var cls = classifyField(d);
      if (issuedIdentifier(d)) return new RegExp(schema.policy.unknownIdentifier,'i').test([d.name,d.id,d.label,d.description].join(' ')) ? 'unknown_required_field' : 'voucher_or_venue_credential_required';
      if (cls === "verification_code" || (!ordinary && /\b(code|otp|pin|passcode)\b/i.test(text))) {
        if(/authenticator|two[ -]*factor|2fa|totp/i.test(visibleText))return 'two_factor';
        if(/\bsms\b|text message|sent.*(?:mobile|phone)/i.test(visibleText))return 'sms_verification';
        return 'verification_code_required';
      }
      if (/voucher|access[ _-]*code|room[ _-]*(number|no)|booking[ _-]*(reference|code|number|id)|\breserv(?:ation|ierung|a)(?:s)?\b|card[ _-]*number/i.test(text)) return "voucher_or_venue_credential_required";
      // An issued reference is not a Persona attribute, even when a model
      // mistakes the word "personal" for a name. Gate it before inference.
      if (/\b(reference|identifier|number|credential)\b/i.test(text)
          && /\b(issued|provided|assigned|reception|front[ -]*desk)\b/i.test(text)) return "voucher_or_venue_credential_required";
      if (/passport|national[ _-]*id|identity[ _-]*(document|number)/i.test(text)) return "government_identity_required";
      if (/sponsor|host[ _-]*email|approver/i.test(text)) return "sponsor_approval_required";
      // A linked description may explain a generic label in another
      // language. Review that evidence before declaring it unspecified.
      if (cls === 'unknown' && !d.description.trim() && schema.policy.unexplainedIdentifier
          && new RegExp(schema.policy.unexplainedIdentifier,'i').test([d.name,d.id,d.label,d.placeholder,d.ariaLabel].join(' '))) return 'unknown_required_field';
      if ((cls === 'account_password' || cls === 'username') && !credentials && accountKind !== 'create')return 'account_credentials_required';
      if(d.autocomplete.split(/\s+/).indexOf('new-password') >= 0 && credentials && credentials.operation !== 'create')return 'account_credentials_required';
      if (d.type === "checkbox" && d.required && consentFor(el, doc) === 'marketing_opt_in') return "marketing_consent_required";
    }
    if (fields.some(function (el) { return descriptorRequired(el) && (el.type || el.getAttribute("type")) === "password"; })
        && !credentials && accountKind !== 'create') return "account_credentials_required";
    var widget = deepQuery(scope, ".g-recaptcha, .h-captcha, .cf-turnstile, iframe[src*=\"recaptcha\"], iframe[src*=\"hcaptcha\"], iframe[src*=\"challenges.cloudflare.com\"]").find(isVisible);
    if (widget) return "captcha_required";
    if (!ordinary) {
      var actions=actionControls(scope).filter(function(el){return isVisible(el) && isEnabled(el)});
      if(actions.some(socialAction) && !possibleActions(scope).length)return 'social_login_required';
      if(!freeBranch && /\b(pay|buy|purchase)\b/i.test(visibleText) && /card|payment|£|€|\$/i.test(visibleText))return 'payment_required';
      return detectFailClosed(textOf(scope)) || detectFailClosed(visibleText);
    }
    return null;
  }

  function isReady(doc, allowReasoning) {
    // The parsed document is enough to inspect controls. `complete` also
    // waits for images and other resources blocked by some captive networks.
    if (doc.readyState === "loading") return false;
    if (unavailablePortalPage(doc)) return true;
    if (chooseForm(doc)) return true;
    return !!findSubmitCandidate(doc.body || doc) || !!(allowReasoning && possibleActions(doc.body || doc).length)
      || deepQuery(doc,'iframe').some(isVisible);
  }

  function waitForReady(doc, timeoutMs, allowReasoning) {
    return new Promise(function (resolve) {
      if (isReady(doc, allowReasoning)) {
        resolve(true);
        return;
      }
      var start = Date.now();
      var settled = false;
      var observer = null;
      var poll = null;
      function finish(val) {
        if (settled) return;
        settled = true;
        if (poll) clearInterval(poll);
        if (observer) observer.disconnect();
        resolve(val);
      }
      var MO = (doc.defaultView && doc.defaultView.MutationObserver) || (typeof MutationObserver !== "undefined" ? MutationObserver : null);
      if (MO) {
        try {
          observer = new MO(function () {
            if (isReady(doc, allowReasoning)) finish(true);
          });
          observer.observe(doc.body || doc.documentElement, { childList: true, subtree: true });
        } catch (e) {
          observer = null;
        }
      }
      poll = setInterval(function () {
        if (isReady(doc, allowReasoning)) {
          finish(true);
          return;
        }
        if (Date.now() - start >= timeoutMs) finish(false);
      }, 100);
    });
  }

  var MONTH_NAMES = ["january","february","march","april","may","june","july","august","september","october","november","december"];
  function normalChoice(value) { return String(value || '').trim().toLowerCase().replace(/[.,]/g,'').replace(/\s+/g,' '); }
  function matchingChoice(options, cls, value) {
    if (value == null) return null;
    var desired = normalChoice(value);
    options = options.filter(function (o) { return !o.disabled && (o.tagName !== 'OPTION' || String(o.value) !== ''); });
    if (cls === 'birth_month') {
      var named = options.filter(function (o) { return MONTH_NAMES.some(function (m) { return normalChoice(textOf(o)).startsWith(m); }); });
      if (named.length) return named.find(function (o) { return normalChoice(textOf(o)).startsWith(MONTH_NAMES[+value-1] || '!'); }) || null;
      // Visible month numbers are meaningful; numeric option values can be zero based.
      var numbered = options.find(function (o) { return /^0?[1-9]$|^1[0-2]$/.test(normalChoice(textOf(o))) && +textOf(o) === +value; });
      if (numbered) return numbered;
      return null; // Let local reasoning interpret unfamiliar month labels.
    }
    if(cls === 'birth_day' || cls === 'birth_year') {
      var displayed=options.find(function(o){return /^\d+$/.test(normalChoice(textOf(o))) && +textOf(o) === +value});
      if(displayed)return displayed;
    }
    return options.find(function (o) {
      var label = normalChoice(textOf(o)), raw = normalChoice(o.value || o.getAttribute('value'));
      if (cls === 'country' && /^(united kingdom|uk|gb|gbr|great britain|britain)$/.test(desired)) return [label,raw].some(function (s) { return /^(united kingdom|uk|gb|gbr|great britain|britain)$/.test(s); });
      if (label === desired || raw === desired) return true;
      if (cls === 'birth_day' || cls === 'birth_year') return raw !== '' && +raw === +value;
      if (cls === 'age') { var range=/([0-9]+)\s*[-–]\s*([0-9]+)/.exec(label); return range && +value >= +range[1] && +value <= +range[2]; }
      if (cls === 'gender' && /prefer not|not specified/i.test(desired)) return /prefer not|not specified/i.test(label);
      if (cls === 'phone_country_code') return new RegExp('(?:^|\\D)'+String(value).replace(/\D/g,'')+'(?:\\D|$)').test(label) || raw === String(value).replace('+','');
      return false;
    }) || null;
  }

  function phoneCandidates(value, country, split, hint) {
    var raw=String(value || ''), digits=raw.replace(/\D/g,'');
    if(!/^(united kingdom|uk|gb|gbr|great britain)$/i.test(country || ''))return Array.from(new Set([raw,raw.replace(/[\s().-]/g,'')]));
    var local=digits.startsWith('0044') ? digits.slice(4) : digits.startsWith('44') && digits.length>10 ? digits.slice(2) : digits.startsWith('0') ? digits.slice(1) : digits;
    if(!local)return [];
    var preferred=split ? local : /international|e\.?164|\+44/i.test(hint || '') ? '+44'+local : raw;
    return Array.from(new Set([preferred,raw,'0'+local,'+44'+local,'0044'+local,local]));
  }
  function fitsConstraints(value,d) {
    if(d.maxLength && value.length>d.maxLength || d.minLength && value.length<d.minLength)return false;
    if(d.pattern) {try{return new RegExp('^(?:'+d.pattern+')$').test(value)}catch(_){return false}}
    return true;
  }

  // Full option labels describe a choice; bare Yes/No answers inherit the
  // question polarity. Never search inherited group wording for a refusal.
  function marketingChoiceDeclines(text, value, optOut) {
    var label = normalChoice(text);
    if (isMarketingLabel(label)) return isOptOutLabel(label);
    if (/^(no thanks|decline|unsubscribe|opt[ _-]*out)$/.test(label)) return true;
    var answer = label || normalChoice(value);
    return (optOut ? /^(yes|true|1)$/ : /^(no|false|0)$/).test(answer);
  }
  function optionDisplayText(option) {
    var label = option.getAttribute('label');
    return label !== null && label !== '' ? label : textOf(option);
  }
  function marketingSelectConsent(el, doc) {
    var d = describeField(el, doc), label = d.label;
    // A wrapping <label> contains its options. Read only the question text,
    // since an answer such as “No thanks” must not change question polarity.
    var labelNode = (el.id ? findLabelFor(el.id,el.ownerDocument || doc) : null) || closestLabel(el);
    function questionText(node) {
      if (node === el) return '';
      if (node.nodeType === 3) return node.textContent || '';
      return toArray(node.childNodes || []).map(questionText).join(' ');
    }
    if (labelNode) label = questionText(labelNode);
    var prompt = [label,d.name,d.id,d.ariaLabel,d.description,d.fieldset].join(' ');
    if (isMarketingLabel(prompt)) return isOptOutLabel(prompt) ? 'marketing_opt_out' : 'marketing_opt_in';
    return /^marketing/.test(d.reasonedIntent || '') ? d.reasonedIntent : 'unknown';
  }
  function isChecked(el) { return el.getAttribute('role') === 'radio' ? el.getAttribute('aria-checked') === 'true' : !!el.checked; }
  function checkChoice(el) { if (el.getAttribute('role') === 'radio') { if (!isChecked(el)) el.click(); } else setNativeChecked(el,true); }
  function widgetState(el) { return JSON.stringify([textOf(el),el.getAttribute('aria-activedescendant'),el.getAttribute('aria-valuetext'),el.value]); }

  function fillOneStep(doc, identity, onlyFields) {
    var form = chooseForm(doc) || doc.body || doc;
    var fields = collectFormFields(form);
    diagnosticStep("form", "Found rendered form", fields.filter(function (f) { return isVisible(f) && isEnabled(f); }).length + " visible controls; " + fields.filter(function (f) { return (f.getAttribute("type") || "") === "checkbox" || f.getAttribute("role") === "checkbox"; }).length + " checkboxes; " + (findSubmitCandidate(form) ? "submit button found" : "no submit button"));
    var filledAny = false;
    var handledRadioGroups = new Set();
    var unresolved = [];

    for (var i = 0; i < fields.length; i++) {
      var el = fields[i];
      if (onlyFields && !onlyFields.has(el)) continue;
      if (!isVisible(el) || !isEnabled(el)) continue;
      var tag = (el.tagName || "").toUpperCase();
      var typeAttr = (el.getAttribute("type") || "").toLowerCase();
      var role = (el.getAttribute("role") || "").toLowerCase();

      if (role === "checkbox") {
        var customConsent = consentFor(el, doc);
        var desiredCheck = customConsent === 'terms' || customConsent === 'marketing_opt_out';
        if (customConsent !== 'unknown'
            && (el.getAttribute("aria-checked") === "true") !== desiredCheck) {
          el.click();
          diagnosticStep("consent", desiredCheck ? "Accepted required terms or marketing opt-out" : "Declined marketing", "", [diagnosticField(describeField(el, doc), customConsent, desiredCheck ? "Consent choice applied" : "Skipped")]);
          filledAny = true;
        }
        if (customConsent === 'unknown' && descriptorRequired(el) && el.getAttribute('aria-checked') !== 'true') unresolved.push({intent:'unknown',type:'checkbox'});
        continue;
      }

      if ((tag === "INPUT" && (typeAttr === "checkbox" || typeAttr === "radio")) || role === 'radio') {
        var label = effectiveLabel(el, doc);
        if (typeAttr === "checkbox") {
          var consent = consentFor(el, doc);
          if (/^marketing/.test(consent)) {
            setNativeChecked(el, consent === 'marketing_opt_out');
            diagnosticStep("consent", consent === 'marketing_opt_out' ? "Selected marketing opt-out" : "Left marketing unchecked", "", [diagnosticField(describeField(el, doc), consent, "Consent choice applied")]);
            continue;
          }
          if (consent === 'terms') {
            setNativeChecked(el, true);
            diagnosticStep("consent", "Ticked terms checkbox", "", [diagnosticField(describeField(el, doc), "terms", "Terms accepted")]);
            filledAny = true;
          }
          if (consent === 'unknown' && descriptorRequired(el) && !el.checked) unresolved.push({intent:'unknown',type:'checkbox'});
        }
        if (typeAttr === "radio" || role === 'radio') {
          var radioParent = role === 'radio' && el.closest ? el.closest('[role="radiogroup"]') : null;
          var groupName = radioParent || el.getAttribute("name") || el.id || String(i);
          if (handledRadioGroups.has(groupName)) continue;
          handledRadioGroups.add(groupName);
          var group = fields.filter(function (candidate) {
            return radioParent ? candidate.getAttribute('role') === 'radio' && candidate.closest('[role="radiogroup"]') === radioParent : (candidate.getAttribute("type") || "").toLowerCase() === "radio" && (candidate.getAttribute("name") || candidate.id || "") === groupName;
          });
          var groupLabel = groupName + " " + group.map(function (candidate) { return effectiveLabel(candidate, doc); }).join(" ");
          if (isMarketingLabel(groupLabel) || group.some(function (candidate) { return /^marketing/.test(consentFor(candidate,doc)); })) {
            var prompt = group.map(function (candidate) {
              var d = describeField(candidate,doc);
              return [d.name,d.fieldset,d.description].join(' ');
            }).join(' ');
            var optOut = isOptOutLabel(prompt);
            var safeChoices = group.filter(function (candidate) {
              return isVisible(candidate) && isEnabled(candidate)
                && marketingChoiceDeclines(effectiveLabel(candidate,doc), candidate.value || candidate.getAttribute('data-value') || '', optOut);
            });
            var decline = safeChoices.length === 1 ? safeChoices[0] : null;
            if (decline) { checkChoice(decline); filledAny = true; }
            else {
              group.forEach(function (candidate) { if (candidate.getAttribute('role') !== 'radio' && isEnabled(candidate)) setNativeChecked(candidate,false); });
              if (group.some(descriptorRequired) || group.some(isChecked)) unresolved.push({ intent: "marketing", type: "radio" });
            }
            continue;
          }
          var isTerms = group.some(function (candidate) { return consentFor(candidate,doc) === 'terms'; });
          if (!isTerms && group.some(isChecked)) continue;
          if (group.some(descriptorRequired)) {
            var groupIntent = classifyField(describeField(el, doc));
            var groupValue = valueForClassification(groupIntent,identity);
            var safe = group.find(function (candidate) {
              var candidateLabel = effectiveLabel(candidate, doc);
              if (!isVisible(candidate) || !isEnabled(candidate)) return false;
              if (isTerms) return !/^(no|false|0)$/i.test(candidate.value || '') && !/\b(no|non|nein)\b|do not|don't|disagree|decline/i.test(candidateLabel) && (/^(yes|true|1)$/i.test(candidate.value || '') || isConsentLabel(candidateLabel) || consentFor(candidate,doc) === 'terms');
              return groupValue != null && (normalChoice(candidateLabel) === normalChoice(groupValue) || normalChoice(candidate.value) === normalChoice(groupValue));
            });
            if (safe) {
              checkChoice(safe);
              filledAny = true;
            }
            else unresolved.push({intent:groupIntent,type:'radio'});
          }
        }
        continue;
      }

      if (typeAttr === "hidden" || el.readOnly === true || el.getAttribute("readonly") !== null) {
        continue; // preserve server-provided defaults/tokens
      }

      if (tag === 'SELECT') {
        var selectConsent = marketingSelectConsent(el,doc);
        if (/^marketing/.test(selectConsent)) {
          var safeOptions = toArray(el.querySelectorAll('option')).filter(function (option) {
            return !option.disabled && isEnabled(option)
              && !(option.parentElement && option.parentElement.tagName === 'OPTGROUP' && option.parentElement.disabled)
              && String(option.value) !== ''
              && optionDisplayText(option).trim() !== ''
              && !/^(choose|select|please select|--)/i.test(optionDisplayText(option).trim())
              && marketingChoiceDeclines(optionDisplayText(option),option.value,selectConsent === 'marketing_opt_out');
          });
          if (safeOptions.length === 1) { setNativeValue(el,safeOptions[0].value); filledAny=true; }
          else unresolved.push({intent:'marketing',type:'select'});
          continue;
        }
      }

      var descriptor = describeField(el, doc);
      var cls = classifyField(descriptor, providerFor(doc));
      var value = valueForClassification(cls, identity);
      var credentials=authorizedCredentials.get(doc);
      if(['username','password','account_password'].indexOf(cls) >= 0 && credentials)value=cls === 'username' ? credentials.username : credentials.password;
      var accountKind=accountFormKind(doc,form);
      if(['password','account_password'].indexOf(cls) >= 0 && !credentials && accountKind === 'create')value=identity.password || null;
      if(cls === 'email' && credentials && accountKind)value=credentials.username;
      if(['password','account_password'].indexOf(cls) >= 0 && !credentials && accountKind !== 'create')value=null;
      var previous=(correctionStates.get(doc) || {})[correctionKey(el,doc)];
      if(previous && previous.length && fitsConstraints(previous[previous.length-1],descriptor))value=previous[previous.length-1];
      if(cls === 'phone' && value) {
        var split=fields.some(function(candidate){return classifyField(describeField(candidate,doc)) === 'phone_country_code'});
        value=phoneCandidates(value,identity.country,split,[descriptor.label,descriptor.placeholder,descriptor.description].join(' ')).find(function(v){return fitsConstraints(v,descriptor)}) || null;
      }

      if (role === 'combobox') {
        var selection = widgetSelections.get(el);
        if (descriptor.required && (!selection || selection.shape !== fieldShape(descriptor) || selection.target !== String(value) || selection.state !== widgetState(el))) unresolved.push({intent:cls,type:'select'});
        continue;
      }

      if (value === null && (descriptor.required || classifyFieldEvidence(descriptor).evidence === 'conflict') && tag !== "SELECT") {
        unresolved.push({ intent: cls, name: descriptor.name || descriptor.id || null, type: descriptor.type });
      }
      if (cls === "dob" && value && descriptor.type !== "date") {
        var date = parseFlexibleDate(value);
        if (date && /dd[\/.\-]mm[\/.\-]yyyy/i.test(descriptor.placeholder + " " + descriptor.label)) value = formatDate(date, "dd/mm/yyyy");
      }
      if (value === null && tag !== "SELECT") {
        diagnosticStep("field", "Field interpretation", "", [diagnosticField(descriptor, cls, "Skipped")]);
        continue;
      }

      if (tag === "SELECT") {
        var opts = toArray(el.querySelectorAll("option"));
        var matched = matchingChoice(opts,cls,value);
        if (matched) { setNativeValue(el,matched.value || matched.getAttribute('value')); filledAny=true; }
        else {
          var resolved=widgetSelections.get(el);
          if (!(resolved && resolved.shape === fieldShape(descriptor) && resolved.target === String(value) && el.value === resolved.value) && descriptor.required) unresolved.push({ intent:cls,name:descriptor.name || descriptor.id || null,type:'select' });
        }
        diagnosticStep("field", "Field interpretation", "Select processed", [diagnosticField(descriptor, cls, matched || (resolved && el.value === resolved.value) ? "Persona " + cls : "Skipped")]);
        continue;
      }

      setNativeValue(el, value);
      diagnosticStep("field", "Field interpretation", "Filled field", [diagnosticField(descriptor, cls, cls === "unknown" ? "Synthesized value" : "Persona " + cls)]);
      filledAny = true;
    }

    return { form: form, filledAny: filledAny, unresolved: unresolved };
  }

  function descriptorRequired(el) {
    var group=el.getAttribute('role') === 'radio' && el.closest ? el.closest('[role="radiogroup"]') : null;
    return el.required === true
      || el.getAttribute("required") !== null
      || el.getAttribute("aria-required") === "true"
      || !!(group && group.getAttribute('aria-required') === 'true');
  }

  function isAttachedToDocument(el, doc) {
    var node = el;
    while (node) {
      if (node === doc.body || node === doc.documentElement) return true;
      node = node.parentElement || (node.getRootNode && node.getRootNode().host);
    }
    return false;
  }

  // ------------------------------------------------------------------
  // Feedback-retry loop. Fires only
  // AFTER a submit+settle where stepOutcome/waitForStepOutcome reported
  // "unchanged" (form still present, nothing detached) — never on the
  // "next"/"submitted" paths, which are untouched. Fail-closed detection
  // in stepLoop still runs first, every round, so an OTP/CAPTCHA/voucher
  // portal that starts clean but reveals a challenge after one submit
  // still surrenders instead of thrashing.
  // ------------------------------------------------------------------

  function hasErrorClass(node) {
    if (!node || typeof node.getAttribute !== "function") return false;
    return ERROR_CLASS_RE.test(node.getAttribute("class") || "");
  }

  // "on or adjacent to" per spec: the field itself, its parent wrapper
  // (and that wrapper's parent, for the common .form-group > .error
  // pattern), or a sibling within the same wrapper (e.g. an inline
  // <span class="error">).
  function hasErrorClassNear(el) {
    if (hasErrorClass(el)) return true;
    var parent = el.parentElement;
    if (!parent) return false;
    if (hasErrorClass(parent)) return true;
    if (hasErrorClass(parent.parentElement)) return true;
    var siblings = toArray(parent.childNodes || []).filter(function (n) {
      return n && n.nodeType === 1;
    });
    for (var i = 0; i < siblings.length; i++) {
      if (siblings[i] !== el && hasErrorClass(siblings[i])) return true;
    }
    return false;
  }

  function isFieldFlaggedInvalid(el) {
    if (el.getAttribute && el.getAttribute("aria-invalid") === "true") return true;
    if (typeof el.checkValidity === "function" && el.checkValidity() === false) return true;
    if (el.validationMessage) return true;
    if (hasErrorClassNear(el)) return true;
    return false;
  }

  var CORRECTABLE_TYPES = { checkbox: true, radio: true, hidden: true, submit: true, button: true };

  function correctableFields(scope) {
    return collectFormFields(scope).filter(function (el) {
      if (!isVisible(el) || !isEnabled(el)) return false;
      var typeAttr = (el.getAttribute("type") || "").toLowerCase();
      return !CORRECTABLE_TYPES[typeAttr];
    });
  }

  // Maps rejection signals back to fields per spec step 2. Per-field
  // signals (aria-invalid/checkValidity/error class) are authoritative;
  // a page-text rejection phrase with NO per-field signal is correlated
  // to a classified field only via a topic keyword in that same text, so
  // we never guess blindly at an unrelated field.
  function detectRejectedFields(doc, scopeEl) {
    var scope = scopeEl || doc.body || doc;
    var fields = correctableFields(scope);
    var flagged = [];
    var flaggedEls = {};
    for (var i = 0; i < fields.length; i++) {
      var el = fields[i];
      if (isFieldFlaggedInvalid(el)) {
        var descriptor = describeField(el, doc);
        flagged.push({ el: el, descriptor: descriptor, cls: classifyField(descriptor) });
        flaggedEls[i] = true;
      }
    }
    if (flagged.length) return flagged;

    var alerts=deepQuery(doc,'[role="alert"],.error,.is-invalid,.has-error').filter(isVisible).map(textOf).join(' ');
    var pageText = alerts || textOf(doc.body || doc);
    if (!alerts && !REJECTION_TEXT_RE.test(pageText)) return flagged;

    for (var j = 0; j < fields.length; j++) {
      var el2 = fields[j];
      var descriptor2 = describeField(el2, doc);
      var cls2 = classifyField(descriptor2);
      var topicHit =
        (cls2 === "phone" && /country\s*code|area\s*code|phone|mobile/i.test(pageText))
        || (cls2 === "postcode" && /postcode|postal/i.test(pageText))
        || (cls2 === "dob" && /date|birth/i.test(pageText))
        || (cls2 === "email" && /e[-\s]?mail/i.test(pageText));
      if (topicHit) {
        flagged.push({ el: el2, descriptor: descriptor2, cls: cls2 });
      }
    }
    return flagged;
  }

  function currentValueOf(el) {
    var v = el.value;
    return v == null ? "" : v;
  }

  function fieldKeyOf(el) {
    return el.id || el.getAttribute("name") || el.getAttribute("placeholder") || el.tagName;
  }

  // Selects get their own value-application path rather than going
  // through setNativeValue — the "unknown" branch of nativeSetterFor
  // resolves to HTMLInputElement's value setter for any non-textarea
  // tag (existing behaviour, untouched), which is only correct for
  // <input>. Selecting-by-option keeps correction correct for <select>
  // without touching that existing helper.
  function setSelectValueByOptionValue(el, optionValue) {
    var opts = toArray(el.querySelectorAll("option"));
    for (var i = 0; i < opts.length; i++) {
      if ((opts[i].getAttribute("value") || opts[i].value) === optionValue) {
        opts[i].selected = true;
      } else {
        opts[i].selected = false;
      }
    }
    fireEvent(el, "input");
    fireEvent(el, "change");
    fireEvent(el, "blur");
  }

  function candidatesForField(field, doc) {
    var tag = (field.el.tagName || "").toUpperCase();
    var current = currentValueOf(field.el);
    if (tag === "SELECT") {
      return [];
    }
    if (
      (field.el.getAttribute("type") || "").toLowerCase() === "radio"
    ) {
      return []; // radio correction handled at group level in fillOneStep already
    }
    switch (field.cls) {
      case "phone":
        var identity=phoneIdentities.get(doc) || {};
        var hint=textOf(doc.body || doc);
        if(!field.descriptor.pattern && !field.descriptor.maxLength && !/international|e\.?164|\+44/i.test(hint))return phoneVariants(current);
        return phoneCandidates(identity.phone || current,identity.country || 'United Kingdom',false,hint).filter(function(v){return fitsConstraints(v,field.descriptor)});
      case "postcode": return postcodeVariants(current);
      case "dob": return dateVariants(current);
      case "email": return emailVariants(current);
      default: return [];
    }
  }

  function applyCorrectionValue(field, value, doc) {
    var tag = (field.el.tagName || "").toUpperCase();
    if (tag === "SELECT") {
      setSelectValueByOptionValue(field.el, value);
    } else {
      setNativeValue(field.el, value);
    }
    var row = diagnosticField(field.descriptor, field.cls, "Alternate format / option");
    row.source = "Formatting rule";
    diagnosticStep("correction", "Adjusted rejected field", "", [row]);
  }

  // Runs up to `maxRounds` correct-and-resubmit cycles. Only re-touches
  // fields detectRejectedFields flags each round — an accepted field is
  // never in that list, so it is never re-touched (spec test (e)).
  function runCorrectionLoop(doc, form, transitionTimeoutMs, maxRounds, limits) {
    limits = limits || {};
    maxRounds = typeof maxRounds === "number" ? maxRounds : 3;
    var triedValues = correctionStates.get(doc) || {}; // Private, never journey/telemetry.
    correctionStates.set(doc,triedValues);

    // VALUE-FREE report, per the reconciled spec (Piece 1 item 4):
    // rejected field names + inferred intents/schema only — never
    // submitted values. `triedValues` stays internal to the loop (it is
    // needed to avoid retrying the same candidate) and is deliberately
    // NOT referenced here, so no code path can leak a value into the
    // returned detail. Raw captures remain local via the existing
    // capture layer; this object is safe to share (safe_report.json).
    function giveUp(flagged) {
      flagged = flagged || detectRejectedFields(doc, form);
      var fieldsStillFailing = flagged.map(function (f) {
        return {
          intent: f.cls,
          name: f.descriptor.name || f.descriptor.id || null,
          label: f.descriptor.label || null,
          type: f.descriptor.type || null,
        };
      });
      var detail = { fieldsStillFailing: fieldsStillFailing };
      if (
        flagged.some(function (f) { return f.cls === "email"; })
      ) {
        // Actionable: the configured email identity itself was refused;
        // the user should pick another relay — we never swap it for them.
        detail.emailIdentityRejected = true;
      }
      return { status: "needs_more", detail: detail };
    }

    function round(n) {
      if (n >= maxRounds || (limits.deadline && Date.now() >= limits.deadline) || (limits.context && limits.context.actions >= limits.maximum)) return Promise.resolve(giveUp());

      // Fail-closed can reveal itself only after a correction attempt
      // (e.g. a phone-format fix unlocks an OTP step) — re-check every
      // round so retries never thrash an unwinnable portal.
      var failClosedReason = workflowGate(doc, form);
      if (failClosedReason) {
        return Promise.resolve({ status: "fail_closed", detail: failClosedReason });
      }

      var flagged = detectRejectedFields(doc, form);
      if (!flagged.length) return Promise.resolve(giveUp(flagged));

      var touchedAny = false;
      for (var i = 0; i < flagged.length; i++) {
        var field = flagged[i];
        var key = correctionKey(field.el,doc) || fieldKeyOf(field.el);
        if (!triedValues[key]) triedValues[key] = [currentValueOf(field.el)];
        var candidates = candidatesForField(field, doc);
        var next = null;
        for (var c = 0; c < candidates.length; c++) {
          if (triedValues[key].indexOf(candidates[c]) === -1) {
            next = candidates[c];
            break;
          }
        }
        if (next !== null) {
          applyCorrectionValue(field, next, doc);
          triedValues[key].push(next);
          touchedAny = true;
        }
      }

      if (!touchedAny) return Promise.resolve(giveUp(flagged));

      var submitEl = findSubmitCandidate(form) || findSubmitCandidate(doc.body || doc);
      if (!submitEl) return Promise.resolve(giveUp(flagged));

      var beforeSignature = stageSnapshot(doc, form).signature;
      if (limits.context) {
        limits.context.actions += 1;
        limits.context.pendingSubmission = true;
        limits.context.trace.push({ signature: beforeSignature, stage: stageSnapshot(doc, form).kind, action: signatureHash(textOf(submitEl) || submitEl.value || ""), fields: stageSnapshot(doc, form).fields, elapsed_ms: Math.max(0, Math.floor(Date.now() - limits.startedAt)), outcome: "corrected" });
        if (limits.publish) limits.publish();
      }
      rememberCorrections(doc,form,limits.onCorrections);
      diagnosticStep("submit", "Submitting portal form", "Validation correction", [], "running");
      submitEl.click();
      return waitForStepOutcome(doc, form, submitEl, transitionTimeoutMs, beforeSignature).then(function (outcome) {
        var afterFailClosed = workflowGate(doc);
        if (afterFailClosed) {
          return { status: "fail_closed", detail: afterFailClosed };
        }
        if (outcome !== "unchanged") {
          return { status: "resolved", outcome: outcome };
        }
        return round(n + 1);
      });
    }

    return round(0);
  }


  function signatureHash(value) {
    var hash = 2166136261;
    for (var i = 0; i < value.length; i++) { hash ^= value.charCodeAt(i); hash = Math.imul(hash, 16777619); }
    return (hash >>> 0).toString(16).padStart(8, "0");
  }

  function stageSnapshot(doc, scope) {
    scope = scope || chooseForm(doc) || doc.body || doc;
    var fields = collectFormFields(scope).filter(function (el) { return isVisible(el) && isEnabled(el); });
    var shape = fields.map(function (el) {
      var d = describeField(el, doc);
      return [d.name || d.id, classifyFieldEvidence(d).intent, d.type, d.required, d.pattern, d.min, d.max,
        el.tagName === "SELECT" ? toArray(el.querySelectorAll("option")).map(function (o) { return [o.value || o.getAttribute("value"),textOf(o)]; }) : [],d.label,d.fieldset,d.description];
    });
    // Include disabled controls: enabling the same button is readiness, not another step.
    var eligibleActions = possibleActions(scope);
    var actions = actionControls(scope)
      .filter(isVisible).filter(function (el) { return actionScore(el) > 0 || eligibleActions.indexOf(el) >= 0; })
      .map(function (el) { return [el.id || "", textOf(el) || el.value || "", el.getAttribute("href") ? "link" : "button"]; });
    var signature = signatureHash(JSON.stringify([shape, actions]));
    var kind = fields.some(function (el) { return classifyField(describeField(el, doc)) === "verification_code"; }) ? "verification"
      : fields.length ? "registration" : actions.length ? "activation" : "completion";
    return { signature: signature, kind: kind, fields: shape.map(function (f) { return { intent: f[1] || "unknown", type: f[2], required: f[3] }; }) };
  }

  function stepOutcome(doc, previousForm, previousSubmit, previousSignature, allowReasoning) {
    var activeForm = chooseForm(doc);
    var scope = activeForm || doc.body || doc;
    var signature = stageSnapshot(doc, scope).signature;
    if (previousSignature && signature !== previousSignature) return (findSubmitCandidate(scope) || (allowReasoning && possibleActions(scope).length)) ? "next" : null;
    if (!isAttachedToDocument(previousForm, doc) || (activeForm && activeForm !== previousForm)
        || (previousSubmit && !isAttachedToDocument(previousSubmit, doc))) {
      return (findSubmitCandidate(scope) || (allowReasoning && possibleActions(scope).length)) ? "next" : null;
    }
    return null;
  }

  function waitForStepOutcome(
    doc,
    previousForm,
    previousSubmit,
    timeoutMs,
    previousSignature, allowReasoning
  ) {
    return new Promise(function (resolve) {
      var immediate = stepOutcome(
        doc,
        previousForm,
        previousSubmit, previousSignature, allowReasoning
      );
      if (immediate) {
        resolve(immediate);
        return;
      }
      var start = Date.now();
      var settled = false;
      var observer = null;
      var poll = null;
      function finish(value) {
        if (settled) return;
        settled = true;
        if (poll) clearInterval(poll);
        if (observer) observer.disconnect();
        resolve(value);
      }
      function inspect() {
        var outcome = stepOutcome(
          doc,
          previousForm,
          previousSubmit, previousSignature, allowReasoning
        );
        if (outcome) {
          finish(outcome);
        } else if (Date.now() - start >= timeoutMs) {
          var changed = previousSignature && stageSnapshot(doc).signature !== previousSignature;
          var formDetached = !isAttachedToDocument(previousForm, doc);
          var submitDetached = previousSubmit
            && !isAttachedToDocument(previousSubmit, doc);
          finish(
            previousSubmit && isAttachedToDocument(previousSubmit, doc) && !isEnabled(previousSubmit) && !changed ? "pending" : changed && (chooseForm(doc) || findSubmitCandidate(doc.body || doc) || (allowReasoning && possibleActions(doc.body || doc).length)) ? "next" : formDetached || submitDetached
              ? "submitted"
              : "unchanged"
          );
        }
      }
      var MO = doc.defaultView && doc.defaultView.MutationObserver;
      if (MO) {
        try {
          observer = new MO(inspect);
          observer.observe(doc.body || doc.documentElement, {
            childList: true,
            subtree: true, attributes: true, characterData: true,
          });
        } catch (e) {
          observer = null;
        }
      }
      poll = setInterval(inspect, 100);
    });
  }

  /**
   * Main entry point. `options`:
   *   - identity: plain object (firstName, lastName, email, phone,
   *     postcode, address, dob, password)
   *   - doc: injection point for tests (defaults to global `document`)
   *   - readinessTimeoutMs: default 8000
   *   - maxSteps: default 4
   * Returns a Promise<{status, detail}>, status one of
   * "submitted" | "unsupported" | "no_form" | "needs_more".
   */

  function metadata(value, maximum) {
    return String(value || '').replace(/https?:\/\/\S+|[\w.+-]+@[\w.-]+\.[a-z]+/gi,'[redacted]').replace(/[a-z0-9_-]{32,}/gi,'[token]').slice(0,maximum);
  }
  function pageContext(doc, scope) {
    return deepQuery(scope || doc,'h1,h2,h3,legend').slice(0,5).map(function (el) { return metadata(textOf(el),100); }).join(' ').slice(0,600);
  }
  function possibleActions(scope) {
    return actionControls(scope)
      .filter(function (el) { var text=[textOf(el),el.value,el.getAttribute('aria-label')].join(' '); return isVisible(el) && isEnabled(el) && !socialAction(el) && !/cancel|\bback\b|\bclose\b|forgot|reset|buy|pay|premium|upgrade|password|facebook|google|apple|accept all cookies|\bhelp\b|privacy|policy|learn more|terms of use/i.test(text) && !/^(checkbox|radio|combobox)$/.test(el.getAttribute('role') || ''); }).slice(0,20);
  }
  function fieldRequest(el, key, doc) {
    var d=describeField(el,doc);
    var options=el.tagName === 'SELECT' ? toArray(el.querySelectorAll('option')) : el.getAttribute('role') === 'combobox' && widgetPopup(el) ? deepQuery(widgetPopup(el),'[role="option"]') : [];
    var context=[d.fieldset,options.length ? 'Displayed options: '+options.slice(0,12).map(textOf).join(' | ') : ''].join(' ');
    return {key:key,label:metadata(d.label,180),description:metadata(d.description,240),name:metadata(d.name || d.id,100),type:d.type,context:metadata(context,240)};
  }
  function reasoningLimit() { return Math.min(12, Math.max(0, (schema.reasoning || {}).maxRequests || 12)); }
  function fieldPassLimit() { return Math.min(3, Math.max(0, (schema.reasoning || {}).maxFieldPasses || 3)); }

  async function askLocal(reasoner, doc, scope, mode, fields, choices, target, limits, review) {
    if (!reasoner || Date.now() >= limits.deadline || (limits.context.reasoningRequests || 0) >= reasoningLimit()) return null;
    var signature=stageSnapshot(doc,scope).signature;
    limits.context.reasoningRequests=(limits.context.reasoningRequests || 0)+1;
    var request={id:'r'+Date.now().toString(36),mode:mode,signature:signature,context:pageContext(doc,scope),fields:fields || [],choices:choices || [],target:metadata(target,80)};
    var account=authorizedCredentials.get(doc);
    if(account)request.accountOperation=account.operation;
    if (review) request.review=review;
    var response,timer;
    try { response=await Promise.race([Promise.resolve().then(function(){return reasoner(request)}),new Promise(function(resolve){timer=setTimeout(function(){resolve(null)},Math.max(0,Math.min(5200,limits.deadline-Date.now())))})]); } catch (_) { return null; } finally { clearTimeout(timer); }
    if (Date.now() >= limits.deadline || signature !== stageSnapshot(doc,scope).signature || !response || typeof response !== 'object' || (!Array.isArray(response.fields) && typeof response.choice !== 'string')) return null;
    return response;
  }

  async function inferUnresolvedFields(doc, scope, reasoner, limits, onlyFields) {
    var changed=new Set();
    // An empty required input is browser-invalid before any submission;
    // that is not portal rejection feedback.
    var rejected=detectRejectedFields(doc,scope).filter(function(field){
      return (limits.context.pendingSubmission && appliedValues.has(field.el))
        || field.el.getAttribute('aria-invalid') === 'true' || hasErrorClassNear(field.el);
    }).map(function(f){return f.el});
    var fields = collectFormFields(scope).filter(function (el) {
      var d = describeField(el, doc);
      var evidence=classifyFieldEvidence(d);
      var state=classificationAttempts.get(el), isRejected=rejected.indexOf(el) >= 0;
      return (!onlyFields || onlyFields.has(el)) && isVisible(el) && isEnabled(el) && !el.readOnly
        && !/^(hidden|password|submit|button)$/.test(d.type)
        && (descriptorRequired(el) || d.type === 'checkbox' || !!(d.label || d.name || d.ariaLabel))
        && !(d.type === 'checkbox' && consentFor(el,doc) !== 'unknown')
        && (classifyField(d) === 'unknown' || evidence.evidence === 'conflict'
          || (isRejected && ['wording','on_device'].indexOf(evidence.evidence) >= 0))
        && (!state || state.shape !== fieldShape(d) || (state.passes < fieldPassLimit() && isRejected && !state.rejectionReviewed));
    }).slice(0, 20);
    var allowed = Object.values(schema.autocomplete).concat(Object.values(schema.names),
      ['terms', 'marketing_opt_in', 'marketing_opt_out', 'account_password', 'verification_code', 'unknown']);
    for (var el of fields) {
      if (Date.now() >= limits.deadline || (limits.context.reasoningRequests || 0) >= reasoningLimit()) break;
      var shape = fieldShape(describeField(el, doc));
      var state=classificationAttempts.get(el);
      if (!state || state.shape !== shape) state={shape:shape,passes:0,answers:[],rejectionReviewed:false};
      var old=reasonedFields.get(el), priorIntent=classifyFieldEvidence(describeField(el,doc)).intent, isRejected=rejected.indexOf(el) >= 0, selected=null;
      if (isRejected) state.rejectionReviewed=true;
      classificationAttempts.set(el,state);
      var alternatives=classifyFieldEvidence(describeField(el,doc)).candidates || [];
      var nearby=collectFormFields(scope).filter(function(other){return other !== el && isVisible(other) && isEnabled(other) && !/password|hidden/.test(other.getAttribute('type') || '') && !issuedIdentifier(describeField(other,doc))}).slice(0,4).map(function(other){var d=describeField(other,doc);return metadata(d.label+' '+d.fieldset,180)});
      while (state.passes < fieldPassLimit() && Date.now() < limits.deadline && (limits.context.reasoningRequests || 0) < reasoningLimit()) {
        var strategy=isRejected ? state.passes === 0 ? 'translate' : 'compare' : state.passes === 0 ? 'read' : state.passes === 1 ? 'translate' : 'compare';
        var review={strategy:strategy,previousIntent:old ? old.intent : state.answers[state.answers.length-1] || null,rejected:isRejected,
          alternatives:Array.from(new Set(alternatives.concat(state.answers))).filter(function(intent){return allowed.indexOf(intent)>=0 && ['username','password','customer_status'].indexOf(intent)<0}).slice(0,4),nearbyFields:strategy === 'compare' ? nearby : []};
        state.passes++;
        var response=await askLocal(reasoner,doc,scope,'fields',[fieldRequest(el,'f0',doc)],[],'',limits,review);
        if (!isAttachedToDocument(el,doc) || fieldShape(describeField(el,doc)) !== shape) break;
        var decision=response && Array.isArray(response.fields) && response.fields.length === 1 && response.fields[0];
        var intent=decision && decision.key === 'f0' && allowed.indexOf(decision.intent)>=0 && ['password','username'].indexOf(decision.intent)<0 ? decision.intent : null;
        if(intent && ['verification_code','account_password','marketing_opt_in'].indexOf(intent)<0
            && typeof decision.translation === 'string' && decision.translation.length<=240) {
          // Cross-check the restated English question with the shared
          // semantics. Never fill translation text as a field value.
          var translatedText=decision.translation+' '+(typeof decision.translatedDescription === 'string' && decision.translatedDescription.length<=240 ? decision.translatedDescription : '');
          var translated=classifyFieldEvidence({label:decision.translation,description:typeof decision.translatedDescription === 'string' && decision.translatedDescription.length<=240 ? decision.translatedDescription : '',type:describeField(el,doc).type});
          if(translated.intent === 'issued_identifier')intent=null;
          else if(translated.intent && allowed.indexOf(translated.intent)>=0 && ['password','username'].indexOf(translated.intent)<0) {
            var nameParts=schema.patterns.filter(function(rule){return ['first_name','last_name'].indexOf(rule.intent)>=0 && new RegExp(rule.pattern,'i').test(translatedText)}).map(function(rule){return rule.intent});
            var explicitFullName=new Set(nameParts).size === 2 || (schema.compoundName && new RegExp(schema.compoundName,'i').test(translatedText)) || (schema.specificFullName && new RegExp(schema.specificFullName,'i').test(translatedText));
            // A generic "name" translation cannot override a more specific
            // but conflicting given/family-name decision.
            intent=translated.intent === 'full_name' && intent !== 'full_name' && !explicitFullName ? null : translated.intent;
          }
        }
        if (numericMeaningConflict(describeField(el,doc).type,intent)) intent=null;
        // Verification and marketing boundaries take effect immediately.
        if (['verification_code','account_password','marketing_opt_in'].indexOf(intent)>=0) {selected=intent;break;}
        // Preserve abstentions as evidence for comparison, rather than
        // presenting only the earlier guess as a candidate.
        state.answers.push(intent || 'unknown');
        if (strategy === 'compare') { selected=intent && intent !== 'unknown' ? intent : null;break; }
        if (strategy === 'translate' && intent && intent !== 'unknown' && state.answers.length >= 2 && state.answers[state.answers.length-2] === intent) {selected=intent;break;}
      }
      if (selected) {
        reasonedFields.set(el,{intent:selected,shape:shape});
        if (priorIntent !== selected) changed.add(el);
      } else if (isRejected) {
        reasonedFields.set(el,{intent:'unknown',shape:shape});changed.add(el);
        if (appliedValues.has(el) && String(el.value) === appliedValues.get(el)) setNativeValue(el,'');
      } else if (!isRejected) {
        // Disagreement or abstention must not leave an earlier answer active.
        reasonedFields.delete(el);
      }
      if (workflowGate(doc, scope)) break;
    }
    return changed;
  }

  async function reconsiderRejectedFields(doc, form, identity, reasoner, limits) {
    if (!reasoner) return null;
    var rejected=new Set(detectRejectedFields(doc,form).map(function(field){return field.el}));
    if (!rejected.size) return null;
    var changed=await inferUnresolvedFields(doc,form,reasoner,limits,rejected);
    var gate=workflowGate(doc,form);
    if (gate) return {status:'fail_closed',detail:gate};
    if (!changed.size) return null;
    var filled=fillOneStep(doc,identity,changed);
    if (filled.unresolved.length) return {status:'needs_more',detail:{fieldsStillFailing:filled.unresolved}};
    var action=findSubmitCandidate(form) || findSubmitCandidate(doc.body || doc);
    if (!action || Date.now()>=limits.deadline || limits.context.actions>=limits.maximum) return null;
    var snapshot=stageSnapshot(doc,form);
    limits.context.actions++;limits.context.pendingSubmission=true;
    limits.context.trace.push({signature:snapshot.signature,stage:snapshot.kind,action:signatureHash(textOf(action)||action.value||''),fields:snapshot.fields,elapsed_ms:Math.max(0,Date.now()-limits.startedAt),outcome:'corrected'});
    limits.publish();rememberCorrections(doc,form,limits.onCorrections);
    diagnosticStep("submit", "Submitting portal form", "Reconsidered field meaning", [], "running");
    action.click();
    var outcome;
    do {
      outcome=await waitForStepOutcome(doc,form,action,Math.max(0,Math.min(2500,limits.deadline-Date.now())),snapshot.signature,true);
      var gate=workflowGate(doc);
      if (gate) return {status:'fail_closed',detail:gate};
    } while (outcome === 'pending' && Date.now()<limits.deadline);
    if (outcome === 'pending') return {status:'needs_more',detail:'Portal did not finish its pending request'};
    return outcome === 'unchanged' ? null : {status:'resolved',outcome:outcome};
  }

  function widgetPopup(el) {
    var root=el.getRootNode ? el.getRootNode() : el.ownerDocument;
    if (!root.getElementById) root=el.ownerDocument;
    var ids=(el.getAttribute('aria-controls') || el.getAttribute('aria-owns') || '').split(/\s+/);
    return ids.map(function (id) { return root.getElementById(id) || el.ownerDocument.getElementById(id); }).find(Boolean) || null;
  }
  // Opening a custom list is a bounded observation action. Reuse that
  // opening when classification and option selection need the same control.
  async function openWidget(doc, scope, el, limits) {
    var shape=fieldShape(describeField(el,doc));
    var attempt=widgetAttempts.get(el);
    if (!attempt || attempt.shape !== shape || (attempt.event.outcome === 'next' && el.getAttribute('aria-expanded') !== 'true')) {
      if(limits.context.actions >= limits.maximum || Date.now() >= limits.deadline)return {options:[],event:null};
      var snapshot=stageSnapshot(doc,scope), actionID=signatureHash('choice '+shape);
      var key=snapshot.signature+':'+actionID;
      if(limits.context.attempts[key])return {options:[],event:null};
      limits.context.attempts[key]=true; limits.context.actions++;
      var event={signature:snapshot.signature,stage:snapshot.kind,action:actionID,fields:snapshot.fields,elapsed_ms:Math.floor(Date.now()-limits.startedAt),outcome:'pending'};
      attempt={shape:shape,event:event}; widgetAttempts.set(el,attempt);
      limits.context.trace.push(event); limits.publish();
      if(el.getAttribute('aria-expanded') !== 'true')el.click();
    }
    var options=[], readyUntil=Math.min(limits.deadline,Date.now()+2000);
    do {
      var popup=widgetPopup(el);
      options=popup ? deepQuery(popup,'[role="option"]').filter(function(o){return isVisible(o) && isEnabled(o)}) : [];
      if(options.length)break;
      await new Promise(function(resolve){setTimeout(resolve,40)});
    } while(Date.now()<readyUntil);
    return {options:options,event:attempt.event};
  }

  async function resolveChoices(doc, scope, identity, reasoner, limits) {
    var controls=collectFormFields(scope).filter(function (el) { return isVisible(el) && isEnabled(el) && descriptorRequired(el) && (el.tagName === 'SELECT' || el.getAttribute('role') === 'combobox'); }).slice(0,20);
    for (var el of controls) {
      var d=describeField(el,doc), cls=classifyField(d), value=valueForClassification(cls,identity);
      if (value == null) continue;
      var custom=el.getAttribute('role') === 'combobox';
      var previous=widgetSelections.get(el);
      if (custom && previous && previous.shape === fieldShape(d) && previous.target === String(value) && previous.state === widgetState(el)) continue;
      if (!custom && previous && previous.shape === fieldShape(d) && previous.target === String(value) && el.value === previous.value) continue;
      var opts=custom ? [] : toArray(el.querySelectorAll('option'));
      if (!custom && matchingChoice(opts,cls,value)) continue;
      var widgetEvent=null;
      if (custom) {
        var opened=await openWidget(doc,scope,el,limits);
        opts=opened.options; widgetEvent=opened.event;
        if(!widgetEvent)continue;
      }
      opts=opts.filter(function (o) { return !o.disabled && isEnabled(o) && (custom || String(o.value) !== '') && !/^(choose|select|please select|--)/i.test(textOf(o).trim()); });
      var option=matchingChoice(opts,cls,value);
      opts=opts.slice(0,60);
      if (!option && opts.length && reasoner) {
        var target=cls === 'birth_month' ? MONTH_NAMES[+value-1] : String(value);
        var choices=opts.map(function (o,i) { return {key:'o'+i,label:metadata(textOf(o),180),value:metadata(o.value || o.getAttribute('data-value') || o.getAttribute('value'),80)}; });
        var observation=JSON.stringify(opts.map(function(o){return [textOf(o),o.value,o.getAttribute('data-value'),o.getAttribute('value')]}));
        var answer=await askLocal(reasoner,doc,scope,'choice',[fieldRequest(el,'f0',doc)],choices,target,limits);
        if(observation !== JSON.stringify(opts.map(function(o){return [textOf(o),o.value,o.getAttribute('data-value'),o.getAttribute('value')]})))continue;
        if (answer && /^o\d+$/.test(answer.choice || '')) option=opts[+answer.choice.slice(1)];
      }
      if (!option || !isAttachedToDocument(el,doc) || !isAttachedToDocument(option,doc) || !isEnabled(option) || !isEnabled(el) || Date.now() >= limits.deadline) { if(widgetEvent)widgetEvent.outcome='unchanged'; continue; }
      if (custom) {
        if (!isVisible(option) || !isEnabled(option)) continue;
        var before=textOf(el), selected=el.getAttribute('aria-activedescendant');
        option.click();
        await new Promise(function (resolve) { setTimeout(resolve,40); });
        if (option.getAttribute('aria-selected') === 'true' || el.getAttribute('aria-expanded') === 'false' || before !== textOf(el) || selected !== el.getAttribute('aria-activedescendant')) {
          widgetSelections.set(el,{shape:fieldShape(describeField(el,doc)),target:String(value),state:widgetState(el)});
          widgetEvent.outcome='next';
        } else widgetEvent.outcome='unchanged';
      } else { setNativeValue(el,option.value || option.getAttribute('value')); widgetSelections.set(el,{shape:fieldShape(d),target:String(value),value:el.value}); }
      limits.publish();
    }
  }

  async function resolveRadioChoices(doc, scope, identity, reasoner, limits) {
    if (!reasoner) return;
    var radios=collectFormFields(scope).filter(function (el) { return isVisible(el) && isEnabled(el) && ((el.getAttribute('type') || '').toLowerCase() === 'radio' || el.getAttribute('role') === 'radio'); });
    var handled=new Set();
    for (var el of radios) {
      var parent=el.getAttribute('role') === 'radio' && el.closest ? el.closest('[role="radiogroup"]') : null;
      var key=parent || el.getAttribute('name') || el;
      if(handled.has(key))continue; handled.add(key);
      var group=radios.filter(function (r) { return parent ? r.closest('[role="radiogroup"]') === parent : (r.getAttribute('name') || r) === key; });
      if (!group.some(descriptorRequired) || group.some(isChecked)) continue;
      var cls=classifyField(describeField(el,doc)), target=valueForClassification(cls,identity);
      if (group.some(function (r) { return /^marketing/.test(consentFor(r,doc)); })) target='Decline marketing communications';
      else if (group.some(function (r) { return consentFor(r,doc) === 'terms'; })) target='Agree to required Wi-Fi access terms';
      if (target == null) continue;
      var answer=await askLocal(reasoner,doc,scope,'choice',[fieldRequest(el,'f0',doc)],group.map(function (r,i) { return {key:'o'+i,label:metadata(effectiveLabel(r,doc),180),value:metadata(r.value || r.getAttribute('data-value'),80)}; }),String(target),limits);
      var chosen=answer && /^o[0-9]{1,3}$/.test(answer.choice || '') && group[+answer.choice.slice(1)];
      if(chosen && isAttachedToDocument(chosen,doc) && isVisible(chosen) && isEnabled(chosen))checkChoice(chosen);
    }
  }

  async function prepareStage(doc, identity, reasoner, limits) {
    var scope=chooseForm(doc) || doc.body || doc;
    var filled;
    for (var pass=0;pass<4 && Date.now()<limits.deadline;pass++) {
      var before=stageSnapshot(doc,scope).signature;
      filled=fillOneStep(doc,identity);
      await Promise.resolve();
      if (before === stageSnapshot(doc,scope).signature) break;
    }
    filled=filled || fillOneStep(doc,identity);
    if (reasoner) {
      for(var widget of collectFormFields(scope).filter(function(el){return isVisible(el) && isEnabled(el) && descriptorRequired(el) && el.getAttribute('role') === 'combobox' && classifyField(describeField(el,doc)) === 'unknown'})) {
        await openWidget(doc,scope,widget,limits);
      }
      await inferUnresolvedFields(doc,scope,reasoner,limits);
      if (workflowGate(doc,scope)) return filled;
      filled=fillOneStep(doc,identity);
    }
    await resolveChoices(doc,scope,identity,reasoner,limits);
    await resolveRadioChoices(doc,scope,identity,reasoner,limits);
    // Do not overwrite a choice translated by the model: baseline filling
    // preserves it when no deterministic equivalent was found.
    filled=fillOneStep(doc,identity);
    return filled;
  }

  async function chooseLocalAction(doc, scope, reasoner, limits) {
    var account=authorizedCredentials.get(doc), existing=account && account.operation === 'existing';
    function eligible(el) {
      return !existing || !/sign\s*up|register|create.*account|new.*account/i.test(textOf(el) || el.value || '');
    }
    // An unfamiliar login button must not lose to a familiar "Create account"
    // link elsewhere on the page. Keep the known-account workflow in its form.
    var baseline=findSubmitCandidates(scope).find(eligible)
      || (!existing && findSubmitCandidate(doc.body || doc));
    // Preserve every established deterministic continuation, including
    // ordinary submit buttons whose wording gives only a weak score.
    if (!reasoner || baseline) return baseline;
    var candidates=possibleActions(scope).filter(eligible);
    if (!candidates.length) return baseline;
    var target=existing ? 'Sign in with the authorized existing account; do not register another account'
      : 'Advance free guest Wi-Fi registration or activate access; decline optional marketing';
    var response=await askLocal(reasoner,doc,scope,'action',[],candidates.map(function (el,i) { return {key:'a'+i,label:metadata(textOf(el) || el.value || el.getAttribute('aria-label'),180),value:''}; }), target,limits);
    if (!response) return baseline;
    if (!/^a\d+$/.test(response.choice || '')) return null;
    return candidates[+response.choice.slice(1)] || null;
  }

  function run(options) {
    options = options || {};
    configureCorrectionLadder(options.correctionLadder);
    if (options.schema) schema = options.schema;
    if (options.profiles) profiles = options.profiles;
    var doc = options.doc || (typeof document !== "undefined" ? document : null);
    var reasoner=options.reasoner || (typeof window !== 'undefined' && window.__wifiAutologinReasoningEnabled && window.__wifiAutologinReason) || null;
    if (!doc) return Promise.resolve({ status: "no_form", detail: "no document available" });
    var context = options.journey || { actions: 0, trace: [], attempts: {} };
    context.trace = context.trace || []; context.attempts = context.attempts || {};
    var maximum = typeof options.maxSteps === 'number' ? options.maxSteps : 8;
    var deadline = options.deadline || Date.now() + 25000;
    var readiness = options.readinessTimeoutMs || 8000;
    var transition = options.transitionTimeoutMs || 2500;
    var startedAt = options.startedAt || Date.now();
    phoneIdentities.set(doc,{phone:(options.identity || {}).phone,country:(options.identity || {}).country});
    if(options.credentials && ['existing','create'].indexOf(options.credentials.operation) >= 0 && typeof options.credentials.username === 'string' && options.credentials.username && typeof options.credentials.password === 'string' && options.credentials.password)authorizedCredentials.set(doc,options.credentials);
    else authorizedCredentials.delete(doc);
    function recoverExistingAccount() {
      var account=authorizedCredentials.get(doc), form=chooseForm(doc);
      // Only reuse the exact account just submitted here. An arbitrary login
      // page or a generic email-format rejection must never authorize this.
      if(!account || account.operation !== 'create' || !(submittedSignup.has(doc) || account.signupSubmitted)
          || accountFormKind(doc,form) !== 'create' || workflowGate(doc,form))return false;
      var errors=deepQuery(doc,'.error,.field_with_errors,.alert,[role="alert"],.login-error').filter(isVisible).map(textOf).join(' ');
      if(!/\b(?:e[ -]?mail|account)\b[^.!?\n]{0,100}\b(?:already (?:been )?(?:taken|registered|exists|in use)|has been taken)\b/i.test(errors))return false;
      authorizedCredentials.set(doc,Object.assign({},account,{operation:'existing'}));
      try{if(window.webkit && window.webkit.messageHandlers.portalAccount)window.webkit.messageHandlers.portalAccount.postMessage({operation:'existing_account'})}catch(_){}
      diagnosticStep('account','Account already registered — trying sign-in','Using the same submitted account',[],'running');
      return true;
    }
    correctionStates.set(doc,options.corrections || correctionStates.get(doc) || {});
    function publish() {
      if (options.onStage) options.onStage(context);
      try { if (window.webkit && window.webkit.messageHandlers.portalJourney) window.webkit.messageHandlers.portalJourney.postMessage(context); } catch (_) {}
    }
    function remaining(limit) { return Math.max(0, Math.min(limit, deadline - Date.now())); }
    function finish(status, detail) {
      publish();
      return { status: status, detail: detail, venue: detectVenue(textOf(doc.body || doc), doc.title),
        provider: providerFor(doc).id, journey: context, trace: context.trace };
    }
    async function step() {
      if (Date.now() >= deadline || context.actions >= maximum) return Promise.resolve(finish("needs_more", "Portal attempt limit reached"));
      if (unavailablePortalPage(doc)) return context.pendingSubmission
        ? finish('submitted','Check internet access after the previous portal submission')
        : finish('unsupported','portal_page_unavailable');
      dismissCookieBanner(doc);
      recoverExistingAccount();
      var selectedForm = chooseForm(doc);
      var scope = selectedForm || doc.body || doc;
      // Reuse only the account submitted in this browser journey. An
      // unrelated returning-user form must never receive a Persona password.
      if (submittedSignup.has(doc) && accountFormKind(doc,scope) === 'existing') {
        var created=authorizedCredentials.get(doc);
        if(created && created.operation === 'create') {
          authorizedCredentials.set(doc,Object.assign({},created,{operation:'existing'}));
          // SPA portals can reveal login without changing their /signup URL.
          // Keep native model authorization aligned with that observed stage.
          try{if(window.webkit && window.webkit.messageHandlers.portalAccount)window.webkit.messageHandlers.portalAccount.postMessage({operation:'existing_account'})}catch(_){}
        }
      }
      // Some portals start with a returning-account panel and a separate
      // free-registration link. Choose that explicit branch before filling.
      var requestedAccount=authorizedCredentials.get(doc);
      var needsCreateBranch=requestedAccount && requestedAccount.operation === 'create' && accountFormKind(doc,scope) === 'existing';
      var needsLoginBranch=requestedAccount && requestedAccount.operation === 'existing' && (!selectedForm || accountFormKind(doc,scope) === 'create');
      var branch = (!selectedForm || needsCreateBranch || needsLoginBranch || workflowGate(doc,scope) === 'account_credentials_required') && findSubmitCandidates(doc.body || doc).find(function (el) {
        var label=textOf(el) || el.value || '';
        return needsLoginBranch ? /^(?:already have an account\??\s*)?(?:log\s*in|sign\s*in)(?:\s+here)?[.!]?$/i.test(label.trim())
          : /guest|free|use (?:your )?email|sign\s*up|create.*account|register/i.test(label);
      });
      if (!selectedForm && !branch && reasoner && workflowGate(doc,scope) === 'account_credentials_required') branch=await chooseLocalAction(doc,scope,reasoner,{context:context,maximum:maximum,deadline:deadline,startedAt:startedAt,publish:publish});
      var gate = branch ? null : workflowGate(doc, scope);
      if (gate) return Promise.resolve(finish("unsupported", gate));
      var limits={context:context,maximum:maximum,deadline:deadline,startedAt:startedAt,publish:publish};
      var filled = branch ? {form: scope, unresolved: []} : await prepareStage(doc, options.identity || {},reasoner,limits);
      gate=branch ? null : workflowGate(doc,filled.form);
      if(gate)return finish('unsupported',gate);
      if (filled.unresolved.length) return Promise.resolve(finish("needs_more", { fieldsStillFailing: filled.unresolved }));
      var action=branch || await chooseLocalAction(doc,filled.form,reasoner,limits);
      if(!action && !reasoner) {
        var readyUntil=Math.min(deadline,Date.now()+readiness);
        while(!action && Date.now()<readyUntil) {
          await new Promise(function(resolve){setTimeout(resolve,100)});
          filled=await prepareStage(doc,options.identity || {},reasoner,limits);
          if(filled.unresolved.length) return finish('needs_more',{fieldsStillFailing:filled.unresolved});
          action=findSubmitCandidate(filled.form);
        }
      }
      // Model-enabled stages also wait for reactive validation, but never
      // repeatedly ask the model about an unchanged set of controls.
      if(!action && reasoner && !possibleActions(filled.form).length) {
        var readyUntil=Math.min(deadline,Date.now()+readiness);
        while(!action && Date.now()<readyUntil) {
          await new Promise(function(resolve){setTimeout(resolve,100)});
          filled=await prepareStage(doc,options.identity || {},reasoner,limits);
          if(filled.unresolved.length)return finish('needs_more',{fieldsStillFailing:filled.unresolved});
          action=findSubmitCandidate(filled.form);
        }
      }
      var snapshot=stageSnapshot(doc,filled.form);
      return Promise.resolve(action).then(async function (action) {
        if (!action || !isAttachedToDocument(action,doc) || !isVisible(action) || !isEnabled(action)) {
          if(context.pendingSubmission && !chooseForm(doc) && !possibleActions(doc.body || doc).length && !deepQuery(doc,'iframe').some(isVisible))return finish('submitted','Previous submission requires connectivity verification');
          return finish("no_form", "No eligible continuation became ready");
        }
        if(Date.now() >= deadline || context.actions >= maximum)return finish('needs_more','Portal attempt limit reached');
        // Re-check after filling: conditional controls can reveal verification.
        var gate = branch ? null : workflowGate(doc, filled.form);
        if (gate) return finish("unsupported", gate);
        var actionID = signatureHash(String(action.tagName) + " " + (textOf(action) || action.value || ""));
        var key = snapshot.signature + ":" + actionID;
        if (context.attempts[key]) {
          if(!detectRejectedFields(doc,filled.form).length)return finish('unsupported','connectivity_unverified');
          var semanticRetry=await reconsiderRejectedFields(doc,filled.form,options.identity || {},reasoner,Object.assign({onCorrections:options.onCorrections},limits));
          if(semanticRetry && semanticRetry.status === 'fail_closed')return finish('unsupported',semanticRetry.detail);
          if(semanticRetry && semanticRetry.status === 'resolved')return semanticRetry.outcome === 'next' ? step() : finish('submitted','Checking connectivity after reinterpretation');
          if(semanticRetry && semanticRetry.status === 'needs_more')return finish('needs_more',semanticRetry.detail);
          var retried=await runCorrectionLoop(doc,filled.form,remaining(transition),correctionLadder.maxCorrectionRounds,{context:context,maximum:maximum,deadline:deadline,startedAt:startedAt,publish:publish,onCorrections:options.onCorrections});
          if(retried.status === 'fail_closed')return finish('unsupported',retried.detail);
          if(retried.status === 'resolved')return retried.outcome === 'next' ? step() : finish('submitted','Checking connectivity after correction');
          return finish('unsupported',Object.assign({reason:'validation_exhausted'},retried.detail));
        }
        context.attempts[key] = true;
        context.actions += 1;
        var event = { signature: snapshot.signature, stage: snapshot.kind, action: actionID,
          fields: snapshot.fields, elapsed_ms: Math.max(0, Math.floor(Date.now() - startedAt)), outcome: "pending" };
        context.trace.push(event);
        context.pendingSubmission = true;
        // Native bridge preserves the action history when navigation destroys JS.
        publish();
        rememberCorrections(doc,filled.form,options.onCorrections);
        diagnosticStep("submit", "Submitting portal form", "", [], "running");
        if (!branch && accountFormKind(doc,filled.form) === 'create') {
          var account=authorizedCredentials.get(doc) || {operation:'create',username:(options.identity || {}).email,password:(options.identity || {}).password};
          if(account.username && account.password) {
            authorizedCredentials.set(doc,account);submittedSignup.add(doc);
            // No credentials cross the native observation bridge. Native
            // code derives the same Persona account and scopes it to this origin.
            try{if(window.webkit && window.webkit.messageHandlers.portalAccount)window.webkit.messageHandlers.portalAccount.postMessage({operation:'signup_submitted'})}catch(_){}
          }
        }
        action.click();
        function settle(limit) {
          return waitForStepOutcome(doc, filled.form, action, remaining(limit), snapshot.signature,!!reasoner).then(function (outcome) {
            if (outcome === "pending" && Date.now() < deadline) return settle(readiness);
            return outcome;
          });
        }
        return settle(transition).then(async function (outcome) {
          event.outcome = outcome;
          if (outcome === "pending") return finish("needs_more", "Portal did not finish its pending request");
          if (recoverExistingAccount()) return step();
          var gate = workflowGate(doc);
          if (gate) return finish("unsupported", gate);
          if(chooseForm(doc) && deepQuery(doc,'.error,.is-invalid,.has-error').some(function(el){return isVisible(el) && textOf(el).trim()}) && !detectRejectedFields(doc,filled.form).length)return finish('unsupported','validation_exhausted');
          if (outcome === "next") return waitForReady(doc, remaining(readiness),!!reasoner).then(step);
          if (outcome === "submitted") return finish("submitted", "Portal submitted for connectivity verification");
          var semanticRetry=await reconsiderRejectedFields(doc,filled.form,options.identity || {},reasoner,Object.assign({onCorrections:options.onCorrections},limits));
          if(semanticRetry && semanticRetry.status === 'fail_closed')return finish('unsupported',semanticRetry.detail);
          if(semanticRetry && semanticRetry.status === 'resolved')return semanticRetry.outcome === 'next' ? step() : finish('submitted','Checking connectivity after reinterpretation');
          if(semanticRetry && semanticRetry.status === 'needs_more')return finish('needs_more',semanticRetry.detail);
          return runCorrectionLoop(doc, filled.form, remaining(transition), correctionLadder.maxCorrectionRounds, {context: context, maximum: maximum, deadline: deadline, startedAt: startedAt, publish: publish,onCorrections:options.onCorrections}).then(function (correction) {
            if (correction.status === "fail_closed") return finish("unsupported", correction.detail);
            if (correction.status === "resolved") {
              event.outcome = "corrected";
              return correction.outcome === "next" ? step() : finish("submitted", "Portal submitted after format correction");
            }
            // A portal may grant access while leaving the same form visible.
            // Report a candidate only when there is no validation rejection.
            if (!detectRejectedFields(doc, filled.form).length) return finish("submitted", "Checking connectivity after unchanged portal");
            return finish("unsupported", Object.assign({reason:'validation_exhausted'},correction.detail));
          });
        });
      });
    }
    if (context.pendingSubmission && doc.readyState === 'complete' && !chooseForm(doc) && !deepQuery(doc,'iframe').some(isVisible)) {
      var boundary=workflowGate(doc);
      if(boundary)return Promise.resolve(finish('unsupported',boundary));
      if(!findSubmitCandidate(doc.body || doc) && !(reasoner && possibleActions(doc.body || doc).length))return Promise.resolve(finish('submitted','Previous submission requires connectivity verification'));
    }
    recoverExistingAccount();
    var initialBoundary=workflowGate(doc);
    var guestAlternative=initialBoundary === 'account_credentials_required' && findSubmitCandidates(doc.body || doc).some(function(el){return /guest|free|use (?:your )?email|sign\s*up|create.*account|register|log\s*in|sign\s*in/i.test(textOf(el) || el.value || '')});
    if(initialBoundary && !guestAlternative)return Promise.resolve(finish('unsupported',initialBoundary));
    return waitForReady(doc, remaining(readiness),!!reasoner).then(function (ready) {
      return ready ? step() : finish("no_form", "Timed out waiting for an eligible portal stage");
    });
  }

  return {
    // Pure, unit-tested directly:
    detectFailClosed: detectFailClosed,
    detectVenue: detectVenue,
    classifyField: classifyField,
    classifyFieldEvidence: classifyFieldEvidence,
    workflowGate: workflowGate,
    stageSnapshot: stageSnapshot,
    signatureHash: signatureHash,
    providerFor: providerFor,
    valueForClassification: valueForClassification,
    isConsentLabel: isConsentLabel,
    isMarketingLabel: isMarketingLabel,
    looksLikeCookieRejectControl: looksLikeCookieRejectControl,
    looksLikeSubmitControl: looksLikeSubmitControl,
    // Pure, unit-tested directly — feedback-retry correction generators:
    phoneVariants: phoneVariants,
    postcodeVariants: postcodeVariants,
    dateVariants: dateVariants,
    emailVariants: emailVariants,
    configureCorrectionLadder: configureCorrectionLadder,
    defaultCorrectionLadder: DEFAULT_CORRECTION_LADDER,
    // DOM-facing, exercised through fixtures:
    effectiveLabel: effectiveLabel,
    describeField: describeField,
    isVisible: isVisible,
    chooseForm: chooseForm,
    dismissCookieBanner: dismissCookieBanner,
    setNativeValue: setNativeValue,
    fillOneStep: fillOneStep,
    isReady: isReady,
    waitForStepOutcome: waitForStepOutcome,
    // DOM-facing, exercised through fixtures — feedback-retry loop:
    detectRejectedFields: detectRejectedFields,
    runCorrectionLoop: runCorrectionLoop,
    // Entry point:
    run: run,
  };
});
