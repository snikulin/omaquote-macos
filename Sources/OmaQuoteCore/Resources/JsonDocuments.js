.pragma library

var maximumCollectionBytes = 1048576
var maximumQuoteCount = 5000
var maximumQuoteTextCharacters = 2000
var maximumAttributionCharacters = 300
var maximumQuoteLineBreaks = 32
var maximumConfigurationBytes = 65536
var maximumStateBytes = 65536
var maximumScreenMargin = 4096
var maximumFontFamilyCharacters = 256
var maximumFontSize = 512

function failure(code, message) {
  return { ok: false, error: { code: code, message: message } }
}

function normalizeText(value) {
  return value.replace(/\r\n?/g, "\n").trim()
}

function isSurrogatePairAt(value, index) {
  return value.charCodeAt(index) >= 0xd800 && value.charCodeAt(index) <= 0xdbff &&
    index + 1 < value.length && value.charCodeAt(index + 1) >= 0xdc00 &&
    value.charCodeAt(index + 1) <= 0xdfff
}

function utf8ByteLength(value) {
  var bytes = 0
  for (var index = 0; index < value.length; index++) {
    var code = value.charCodeAt(index)
    if (code < 0x80) bytes += 1
    else if (code < 0x800) bytes += 2
    else if (isSurrogatePairAt(value, index)) {
      bytes += 4
      index += 1
    } else bytes += 3
  }
  return bytes
}

function unicodeCharacterCount(value) {
  var count = 0
  for (var index = 0; index < value.length; index++) {
    if (isSurrogatePairAt(value, index)) index += 1
    count += 1
  }
  return count
}

function parseCollectionBytes(rawBytes) {
  var bytes
  try {
    bytes = new Uint8Array(rawBytes)
  } catch (error) {
    return failure("invalid-utf8", "Collection Document bytes could not be read")
  }

  if (bytes.length > maximumCollectionBytes)
    return failure("collection-too-large", "Quote Collection exceeds " + maximumCollectionBytes + " bytes")

  var chunks = []
  var codeUnits = []

  function flushCodeUnits() {
    if (codeUnits.length === 0) return
    chunks.push(String.fromCharCode.apply(null, codeUnits))
    codeUnits = []
  }

  function appendCodePoint(codePoint) {
    if (codePoint <= 0xffff) {
      codeUnits.push(codePoint)
    } else {
      var adjusted = codePoint - 0x10000
      codeUnits.push(0xd800 + (adjusted >> 10), 0xdc00 + (adjusted & 0x3ff))
    }
    if (codeUnits.length >= 4096) flushCodeUnits()
  }

  function invalidUtf8(byteIndex) {
    return failure("invalid-utf8", "Collection Document contains invalid UTF-8 at byte " + byteIndex)
  }

  function isContinuation(byte) {
    return byte >= 0x80 && byte <= 0xbf
  }

  for (var index = 0; index < bytes.length;) {
    var first = bytes[index]
    if (first <= 0x7f) {
      appendCodePoint(first)
      index += 1
      continue
    }

    if (first >= 0xc2 && first <= 0xdf) {
      if (index + 1 >= bytes.length || !isContinuation(bytes[index + 1]))
        return invalidUtf8(index)
      appendCodePoint(((first & 0x1f) << 6) | (bytes[index + 1] & 0x3f))
      index += 2
      continue
    }

    if (first >= 0xe0 && first <= 0xef) {
      if (index + 2 >= bytes.length || !isContinuation(bytes[index + 1]) ||
          !isContinuation(bytes[index + 2]) ||
          (first === 0xe0 && bytes[index + 1] < 0xa0) ||
          (first === 0xed && bytes[index + 1] > 0x9f))
        return invalidUtf8(index)
      appendCodePoint(((first & 0x0f) << 12) | ((bytes[index + 1] & 0x3f) << 6) |
        (bytes[index + 2] & 0x3f))
      index += 3
      continue
    }

    if (first >= 0xf0 && first <= 0xf4) {
      if (index + 3 >= bytes.length || !isContinuation(bytes[index + 1]) ||
          !isContinuation(bytes[index + 2]) || !isContinuation(bytes[index + 3]) ||
          (first === 0xf0 && bytes[index + 1] < 0x90) ||
          (first === 0xf4 && bytes[index + 1] > 0x8f))
        return invalidUtf8(index)
      appendCodePoint(((first & 0x07) << 18) | ((bytes[index + 1] & 0x3f) << 12) |
        ((bytes[index + 2] & 0x3f) << 6) | (bytes[index + 3] & 0x3f))
      index += 4
      continue
    }

    return invalidUtf8(index)
  }

  flushCodeUnits()
  return parseCollection(chunks.join(""))
}

function duplicateObjectKey(rawText) {
  var contexts = []
  var index = 0

  function completeValue() {
    if (contexts.length === 0) return
    contexts[contexts.length - 1].phase = "comma-or-end"
  }

  while (index < rawText.length) {
    var character = rawText.charAt(index)

    if (/\s/.test(character)) {
      index += 1
      continue
    }

    if (character === '"') {
      var start = index
      index += 1
      while (index < rawText.length) {
        if (rawText.charAt(index) === "\\") {
          index += 2
          continue
        }
        if (rawText.charAt(index) === '"') {
          index += 1
          break
        }
        index += 1
      }

      var context = contexts.length > 0 ? contexts[contexts.length - 1] : null
      if (context && context.type === "object" && context.phase === "key-or-end") {
        var key = JSON.parse(rawText.slice(start, index))
        if (Object.prototype.hasOwnProperty.call(context.keys, key)) return key
        context.keys[key] = true
        context.phase = "colon"
      } else {
        completeValue()
      }
      continue
    }

    if (character === "{") {
      contexts.push({ type: "object", phase: "key-or-end", keys: ({}) })
      index += 1
      continue
    }

    if (character === "[") {
      contexts.push({ type: "array", phase: "value-or-end" })
      index += 1
      continue
    }

    if (character === "}" || character === "]") {
      contexts.pop()
      index += 1
      completeValue()
      continue
    }

    if (character === ":") {
      contexts[contexts.length - 1].phase = "value"
      index += 1
      continue
    }

    if (character === ",") {
      var container = contexts[contexts.length - 1]
      container.phase = container.type === "object" ? "key-or-end" : "value-or-end"
      index += 1
      continue
    }

    while (index < rawText.length && !/[\s,}\]]/.test(rawText.charAt(index))) index += 1
    completeValue()
  }

  return null
}

function firstUnknownField(value, allowedFields) {
  var fields = Object.keys(value)
  for (var index = 0; index < fields.length; index++) {
    if (allowedFields.indexOf(fields[index]) === -1) return fields[index]
  }
  return null
}

function isNumberInRange(value, minimum, maximum, minimumInclusive) {
  if (typeof value !== "number" || !Number.isFinite(value)) return false
  return (minimumInclusive ? value >= minimum : value > minimum) && value <= maximum
}

function isIntegerInRange(value, minimum, maximum) {
  return Number.isInteger(value) && value >= minimum && value <= maximum
}

function isNullableColor(value) {
  return value === null || (typeof value === "string" && /^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$/.test(value))
}

function defaultConfiguration() {
  return {
    version: 1,
    visible: true,
    selectionMode: "shuffle",
    advanceOnWallpaperChange: true,
    intervalMinutes: 0,
    horizontalAlignment: "right",
    verticalPositionRatio: 0.4,
    maximumWidthRatio: 0.7,
    maximumHeightRatio: 0.8,
    screenMargin: 32,
    fontFamily: null,
    preferredFontSize: 24,
    minimumFontSize: 12,
    textColor: null,
    attributionColor: null,
    backdropColor: null,
    backdropOpacity: 0.55,
    shadow: false
  }
}

function parseCollection(rawText) {
  rawText = String(rawText || "")
  if (utf8ByteLength(rawText) > maximumCollectionBytes)
    return failure("collection-too-large", "Quote Collection exceeds " + maximumCollectionBytes + " bytes")

  var document

  try {
    document = JSON.parse(rawText)
  } catch (error) {
    return failure("invalid-json", String(error))
  }

  var duplicateKey = duplicateObjectKey(rawText)
  if (duplicateKey !== null)
    return failure("duplicate-key", "Collection Document contains duplicate key: " + duplicateKey)

  if (!document || Array.isArray(document) || typeof document !== "object")
    return failure("invalid-collection", "Collection Document must be an object")
  var unknownDocumentField = firstUnknownField(document, ["version", "quotes"])
  if (unknownDocumentField !== null)
    return failure("unknown-field", "Collection Document contains unknown field: " + unknownDocumentField)
  if (document.version !== 1)
    return failure("unsupported-version", "Collection Document version must be 1")
  if (!Array.isArray(document.quotes))
    return failure("invalid-quotes", "Collection Document quotes must be an array")
  if (document.quotes.length > maximumQuoteCount)
    return failure("too-many-quotes", "Quote Collection exceeds " + maximumQuoteCount + " Quotes")

  var quotes = []
  var quoteIdentities = ({})
  for (var index = 0; index < document.quotes.length; index++) {
    var quote = document.quotes[index]
    if (!quote || Array.isArray(quote) || typeof quote !== "object")
      return failure("invalid-quote", "Quote at index " + index + " must be an object")
    var unknownQuoteField = firstUnknownField(quote, ["text", "attribution"])
    if (unknownQuoteField !== null)
      return failure("unknown-field", "Quote at index " + index + " contains unknown field: " + unknownQuoteField)
    if (typeof quote.text !== "string" || normalizeText(quote.text) === "")
      return failure("invalid-quote-text", "Quote at index " + index + " must have non-empty text")
    if (quote.attribution !== undefined &&
        (typeof quote.attribution !== "string" || normalizeText(quote.attribution) === ""))
      return failure("invalid-attribution", "Quote at index " + index + " has invalid attribution")

    var normalizedQuote = { text: normalizeText(quote.text) }
    if (unicodeCharacterCount(normalizedQuote.text) > maximumQuoteTextCharacters)
      return failure("quote-text-too-long", "Quote at index " + index + " exceeds " +
        maximumQuoteTextCharacters + " characters")
    var lineBreaks = normalizedQuote.text.match(/\n/g)
    if (lineBreaks && lineBreaks.length > maximumQuoteLineBreaks)
      return failure("too-many-line-breaks", "Quote at index " + index + " exceeds " +
        maximumQuoteLineBreaks + " line breaks")
    if (quote.attribution !== undefined) {
      normalizedQuote.attribution = normalizeText(quote.attribution)
      if (unicodeCharacterCount(normalizedQuote.attribution) > maximumAttributionCharacters)
        return failure("attribution-too-long", "Attribution at index " + index + " exceeds " +
          maximumAttributionCharacters + " characters")
    }
    var identity = JSON.stringify([normalizedQuote.text, normalizedQuote.attribution || null])
    if (Object.prototype.hasOwnProperty.call(quoteIdentities, identity))
      return failure("duplicate-quote", "Quote at index " + index + " duplicates an earlier Quote Identity")
    quoteIdentities[identity] = true
    quotes.push(normalizedQuote)
  }

  return { ok: true, value: { version: 1, quotes: quotes } }
}

function parseConfiguration(rawText) {
  rawText = String(rawText || "")
  if (utf8ByteLength(rawText) > maximumConfigurationBytes)
    return failure("configuration-too-large", "Configuration exceeds " + maximumConfigurationBytes + " bytes")

  var document
  try {
    document = JSON.parse(rawText)
  } catch (error) {
    return failure("invalid-json", String(error))
  }

  var duplicateKey = duplicateObjectKey(rawText)
  if (duplicateKey !== null)
    return failure("duplicate-key", "Configuration contains duplicate key: " + duplicateKey)
  if (!document || Array.isArray(document) || typeof document !== "object")
    return failure("invalid-configuration", "Configuration must be an object")

  var allowedFields = [
    "version", "visible", "selectionMode", "advanceOnWallpaperChange",
    "intervalMinutes", "horizontalAlignment", "verticalPositionRatio", "maximumWidthRatio",
    "maximumHeightRatio", "screenMargin", "fontFamily", "preferredFontSize",
    "minimumFontSize", "textColor", "attributionColor", "backdropColor",
    "backdropOpacity", "shadow"
  ]
  var unknownField = firstUnknownField(document, allowedFields)
  if (unknownField !== null)
    return failure("unknown-field", "Configuration contains unknown field: " + unknownField)
  if (document.version !== 1)
    return failure("unsupported-version", "Configuration version must be 1")
  if (document.visible !== undefined && typeof document.visible !== "boolean")
    return failure("invalid-visible", "Configuration visible must be a boolean")
  if (document.selectionMode !== undefined && document.selectionMode !== "shuffle" &&
      document.selectionMode !== "random")
    return failure("invalid-selection-mode", "Configuration Selection Mode must be shuffle or random")
  if (document.advanceOnWallpaperChange !== undefined &&
      typeof document.advanceOnWallpaperChange !== "boolean")
    return failure("invalid-wallpaper-advance",
      "Configuration advanceOnWallpaperChange must be a boolean")
  if (document.intervalMinutes !== undefined &&
      !isIntegerInRange(document.intervalMinutes, 0, 1440))
    return failure("invalid-interval",
      "Configuration intervalMinutes must be an integer between 0 and 1440")
  if (document.horizontalAlignment !== undefined &&
      ["left", "center", "right"].indexOf(document.horizontalAlignment) === -1)
    return failure("invalid-horizontal-alignment",
      "Configuration horizontalAlignment must be left, center, or right")
  if (document.verticalPositionRatio !== undefined &&
      !isNumberInRange(document.verticalPositionRatio, 0, 1, true))
    return failure("invalid-vertical-position",
      "Configuration verticalPositionRatio must be between 0 and 1")
  if (document.maximumWidthRatio !== undefined &&
      !isNumberInRange(document.maximumWidthRatio, 0, 1, true))
    return failure("invalid-maximum-width",
      "Configuration maximumWidthRatio must be between 0 and 1")
  if (document.maximumHeightRatio !== undefined &&
      !isNumberInRange(document.maximumHeightRatio, 0, 1, true))
    return failure("invalid-maximum-height",
      "Configuration maximumHeightRatio must be between 0 and 1")
  if (document.screenMargin !== undefined &&
      !isIntegerInRange(document.screenMargin, 0, maximumScreenMargin))
    return failure("invalid-screen-margin",
      "Configuration screenMargin must be an integer between 0 and " + maximumScreenMargin)
  if (document.fontFamily !== undefined && document.fontFamily !== null &&
      (typeof document.fontFamily !== "string" || document.fontFamily.trim() === "" ||
       unicodeCharacterCount(document.fontFamily) > maximumFontFamilyCharacters))
    return failure("invalid-font-family",
      "Configuration fontFamily must be null or a non-empty string of at most " +
        maximumFontFamilyCharacters + " characters")
  if (document.preferredFontSize !== undefined &&
      !isIntegerInRange(document.preferredFontSize, 1, maximumFontSize))
    return failure("invalid-preferred-font-size",
      "Configuration preferredFontSize must be an integer between 1 and " + maximumFontSize)
  if (document.minimumFontSize !== undefined &&
      !isIntegerInRange(document.minimumFontSize, 1, maximumFontSize))
    return failure("invalid-minimum-font-size",
      "Configuration minimumFontSize must be an integer between 1 and " + maximumFontSize)
  var effectivePreferredFontSize = document.preferredFontSize === undefined
    ? 24 : document.preferredFontSize
  var effectiveMinimumFontSize = document.minimumFontSize === undefined
    ? 12 : document.minimumFontSize
  if (effectiveMinimumFontSize > effectivePreferredFontSize)
    return failure("invalid-font-size-range",
      "Configuration minimumFontSize must not exceed preferredFontSize")
  var colorFields = ["textColor", "attributionColor", "backdropColor"]
  for (var colorIndex = 0; colorIndex < colorFields.length; colorIndex++) {
    var colorField = colorFields[colorIndex]
    if (document[colorField] !== undefined && !isNullableColor(document[colorField]))
      return failure("invalid-" + colorField.replace(/([A-Z])/g, "-$1").toLowerCase(),
        "Configuration " + colorField + " must be null, #RRGGBB, or #AARRGGBB")
  }
  if (document.backdropOpacity !== undefined &&
      !isNumberInRange(document.backdropOpacity, 0, 1, true))
    return failure("invalid-backdrop-opacity",
      "Configuration backdropOpacity must be between 0 and 1")
  if (document.shadow !== undefined && typeof document.shadow !== "boolean")
    return failure("invalid-shadow", "Configuration shadow must be a boolean")

  var configuration = defaultConfiguration()
  if (document.visible !== undefined) configuration.visible = document.visible
  if (document.selectionMode !== undefined) configuration.selectionMode = document.selectionMode
  if (document.advanceOnWallpaperChange !== undefined)
    configuration.advanceOnWallpaperChange = document.advanceOnWallpaperChange
  for (var fieldIndex = 4; fieldIndex < allowedFields.length; fieldIndex++) {
    var field = allowedFields[fieldIndex]
    if (document[field] !== undefined) configuration[field] = document[field]
  }
  return { ok: true, value: configuration }
}

function normalizedStateQuote(value) {
  if (value === null) return { ok: true, value: null }
  if (!value || Array.isArray(value) || typeof value !== "object")
    return failure("invalid-state", "Persisted state activeQuote must be a Quote or null")
  var unknownField = firstUnknownField(value, ["text", "attribution"])
  if (unknownField !== null)
    return failure("unknown-field", "Persisted state activeQuote contains unknown field: " + unknownField)
  if (typeof value.text !== "string" || normalizeText(value.text) === "")
    return failure("invalid-state", "Persisted state activeQuote must have non-empty text")
  if (value.attribution !== undefined &&
      (typeof value.attribution !== "string" || normalizeText(value.attribution) === ""))
    return failure("invalid-state", "Persisted state activeQuote has invalid attribution")

  var quote = { text: normalizeText(value.text) }
  if (value.attribution !== undefined) quote.attribution = normalizeText(value.attribution)
  return { ok: true, value: quote }
}

function parseState(rawText) {
  rawText = String(rawText || "")
  if (utf8ByteLength(rawText) > maximumStateBytes)
    return failure("state-too-large", "Persisted state exceeds " + maximumStateBytes + " bytes")

  var document
  try {
    document = JSON.parse(rawText)
  } catch (error) {
    return failure("invalid-json", String(error))
  }

  var duplicateKey = duplicateObjectKey(rawText)
  if (duplicateKey !== null)
    return failure("duplicate-key", "Persisted state contains duplicate key: " + duplicateKey)
  if (!document || Array.isArray(document) || typeof document !== "object")
    return failure("invalid-state", "Persisted state must be an object")

  var allowedFields = [
    "version", "collectionFingerprint", "selectionMode", "activeQuote", "shuffleRemaining"
  ]
  var unknownField = firstUnknownField(document, allowedFields)
  if (unknownField !== null)
    return failure("unknown-field", "Persisted state contains unknown field: " + unknownField)
  if (document.version !== 1)
    return failure("unsupported-version", "Persisted state version must be 1")
  if (typeof document.collectionFingerprint !== "string" ||
      !/^fnv1a32:[0-9a-f]{8}$/.test(document.collectionFingerprint))
    return failure("invalid-state", "Persisted state has an invalid collection fingerprint")
  if (document.selectionMode !== "shuffle" && document.selectionMode !== "random")
    return failure("invalid-state", "Persisted state has an invalid Selection Mode")
  if (!Object.prototype.hasOwnProperty.call(document, "activeQuote"))
    return failure("invalid-state", "Persisted state must contain activeQuote")

  var activeQuote = normalizedStateQuote(document.activeQuote)
  if (!activeQuote.ok) return activeQuote
  if (!Array.isArray(document.shuffleRemaining) || document.shuffleRemaining.length > 5000)
    return failure("invalid-state", "Persisted state has an invalid Shuffle cycle")

  var seen = ({})
  var remaining = []
  for (var index = 0; index < document.shuffleRemaining.length; index++) {
    var quoteIndex = document.shuffleRemaining[index]
    if (!Number.isInteger(quoteIndex) || quoteIndex < 0 || quoteIndex >= 5000 ||
        Object.prototype.hasOwnProperty.call(seen, quoteIndex))
      return failure("invalid-state", "Persisted state has an invalid Shuffle index")
    seen[quoteIndex] = true
    remaining.push(quoteIndex)
  }

  return {
    ok: true,
    value: {
      version: 1,
      collectionFingerprint: document.collectionFingerprint,
      selectionMode: document.selectionMode,
      activeQuote: activeQuote.value,
      shuffleRemaining: remaining
    }
  }
}

function serializeState(state) {
  var serialized
  try {
    serialized = JSON.stringify(state)
  } catch (error) {
    return failure("invalid-state", String(error))
  }

  if (utf8ByteLength(serialized) + 1 > maximumStateBytes)
    return failure("state-too-large", "Persisted state exceeds " + maximumStateBytes + " bytes")
  var validated = parseState(serialized)
  if (!validated.ok) return validated
  return { ok: true, value: serialized + "\n" }
}
