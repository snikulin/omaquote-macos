.pragma library

var maximumPresentationHistoryEntries = 100

function boundedRandom(randomValue) {
  return Math.max(0, Math.min(Number(randomValue), 0.9999999999999999))
}

function randomIndex(length, randomValue) {
  if (length <= 0) return -1
  return Math.floor(boundedRandom(randomValue) * length)
}

function randomAt(randomValues, index) {
  if (Array.isArray(randomValues) && index < randomValues.length)
    return randomValues[index]
  if (typeof randomValues === "number" && index === 0) return randomValues
  return 0
}

function shuffledIndices(length, randomValues) {
  var indices = []
  for (var index = 0; index < length; index++) indices.push(index)

  var randomOffset = 0
  for (var remaining = length - 1; remaining > 0; remaining--) {
    var selected = randomIndex(remaining + 1, randomAt(randomValues, randomOffset))
    var held = indices[remaining]
    indices[remaining] = indices[selected]
    indices[selected] = held
    randomOffset += 1
  }
  return indices
}

function quoteIdentity(quote) {
  if (!quote) return "null"
  return JSON.stringify([quote.text, quote.attribution || null])
}

function collectionFingerprint(quotes) {
  var serialized = JSON.stringify(quotes)
  var hash = 2166136261
  for (var index = 0; index < serialized.length; index++) {
    hash ^= serialized.charCodeAt(index)
    hash = Math.imul(hash, 16777619)
  }
  var hexadecimal = (hash >>> 0).toString(16)
  while (hexadecimal.length < 8) hexadecimal = "0" + hexadecimal
  return "fnv1a32:" + hexadecimal
}

function copiedQuote(quote) {
  if (!quote) return null
  var copy = { text: quote.text }
  if (quote.attribution !== undefined) copy.attribution = quote.attribution
  return copy
}

var reportedErrorFields = [
  "collectionError", "configurationError", "wallpaperError", "intervalError", "stateError",
  "presentationError"
]

function latestErrorSource(model, sequences) {
  var source = null
  var latestSequence = -1
  for (var index = 0; index < reportedErrorFields.length; index++) {
    var field = reportedErrorFields[index]
    if (model[field] && Number(sequences[field] || 0) > latestSequence) {
      source = field
      latestSequence = Number(sequences[field] || 0)
    }
  }
  return source
}

function withReportedHealth(model, changes) {
  var nextModel = Object.assign({}, model, changes)
  var errorSequences = Object.assign({}, model.errorSequences || ({}))
  var errorSequence = Number(model.errorSequence || 0)
  for (var index = 0; index < reportedErrorFields.length; index++) {
    var field = reportedErrorFields[index]
    if (!Object.prototype.hasOwnProperty.call(changes, field)) continue
    if (changes[field]) {
      errorSequence += 1
      errorSequences[field] = errorSequence
    } else {
      delete errorSequences[field]
    }
  }
  var lastErrorSource = latestErrorSource(nextModel, errorSequences)
  nextModel.errorSequence = errorSequence
  nextModel.errorSequences = errorSequences
  nextModel.health = nextModel.stateError ? "degraded-state" : "healthy"
  nextModel.lastErrorSource = lastErrorSource
  nextModel.lastError = lastErrorSource ? nextModel[lastErrorSource] : null
  return nextModel
}

function stateFor(model) {
  return {
    version: 1,
    collectionFingerprint: model.collectionFingerprint,
    selectionMode: model.selectionMode,
    activeQuote: copiedQuote(model.activeQuote),
    shuffleRemaining: model.selectionMode === "shuffle" ? model.shuffleRemaining.slice() : []
  }
}

function effectsForSelection(model, shouldPersist, recoverHealthOnSave) {
  var effects = [{ type: "update-presentation", quote: model.activeQuote }]
  if (shouldPersist) effects.push({
    type: "persist-state",
    state: stateFor(model),
    recoverHealthOnSave: Boolean(recoverHealthOnSave)
  })
  return effects
}

function selectionSnapshot(activeQuoteIndex, shuffleRemaining, quote) {
  return {
    activeQuoteIndex: activeQuoteIndex,
    quoteIdentity: quoteIdentity(quote),
    shuffleRemaining: shuffleRemaining.slice()
  }
}

function currentSelectionSnapshot(model) {
  return selectionSnapshot(model.activeQuoteIndex, model.shuffleRemaining, model.activeQuote)
}

function restartIntervalEffect(model) {
  return { type: "restart-interval", intervalMinutes: model.intervalMinutes }
}

function intervalRestartEffects(model) {
  return model.intervalMinutes > 0 && !model.automaticAdvancePaused
    ? [restartIntervalEffect(model)] : []
}

function findQuoteIndex(quotes, quote) {
  return findQuoteIndexByIdentity(quotes, quoteIdentity(quote))
}

function findQuoteIndexByIdentity(quotes, identity) {
  for (var index = 0; index < quotes.length; index++) {
    if (quoteIdentity(quotes[index]) === identity) return index
  }
  return -1
}

function quoteIndexByIdentity(quotes) {
  var indexes = Object.create(null)
  for (var index = 0; index < quotes.length; index++)
    indexes[quoteIdentity(quotes[index])] = index
  return indexes
}

function sameQuoteCollections(left, right) {
  if (left.length !== right.length) return false
  for (var index = 0; index < left.length; index++) {
    if (quoteIdentity(left[index]) !== quoteIdentity(right[index])) return false
  }
  return true
}

function restoredSelection(quotes, mode, fingerprint, persistedState) {
  if (!persistedState || persistedState.version !== 1 ||
      persistedState.collectionFingerprint !== fingerprint ||
      persistedState.selectionMode !== mode)
    return null

  if (quotes.length === 0) {
    if (persistedState.activeQuote !== null ||
        !Array.isArray(persistedState.shuffleRemaining) ||
        persistedState.shuffleRemaining.length !== 0)
      return null
    return { activeIndex: -1, shuffleRemaining: [] }
  }

  var activeIndex = findQuoteIndex(quotes, persistedState.activeQuote)
  if (activeIndex < 0) return null

  var remaining = persistedState.shuffleRemaining
  if (!Array.isArray(remaining)) return null
  if (mode === "random" && remaining.length !== 0) return null

  var seen = ({})
  for (var index = 0; index < remaining.length; index++) {
    var quoteIndex = remaining[index]
    if (!Number.isInteger(quoteIndex) || quoteIndex < 0 || quoteIndex >= quotes.length ||
        quoteIndex === activeIndex || Object.prototype.hasOwnProperty.call(seen, quoteIndex))
      return null
    seen[quoteIndex] = true
  }

  return { activeIndex: activeIndex, shuffleRemaining: remaining.slice() }
}

function initialSelection(quotes, mode, randomValues) {
  if (quotes.length === 0) return { activeIndex: -1, shuffleRemaining: [] }
  if (mode === "random") {
    return {
      activeIndex: randomIndex(quotes.length, randomAt(randomValues, 0)),
      shuffleRemaining: []
    }
  }

  var cycle = shuffledIndices(quotes.length, randomValues)
  return { activeIndex: cycle.shift(), shuffleRemaining: cycle }
}

function shuffleWithoutActive(quotes, activeIndex, randomValues) {
  var shuffled = shuffledIndices(quotes.length, randomValues)
  var remaining = []
  for (var index = 0; index < shuffled.length; index++) {
    if (shuffled[index] !== activeIndex) remaining.push(shuffled[index])
  }
  return remaining
}

function initialize(collection, options) {
  options = options || ({})
  var quotes = collection && Array.isArray(collection.quotes) ? collection.quotes : []
  var configuration = options.configuration || ({
    version: 1,
    visible: options.runtimeVisibility === undefined ? true : Boolean(options.runtimeVisibility),
    selectionMode: options.selectionMode === "random" ? "random" : "shuffle",
    advanceOnWallpaperChange: true
  })
  var mode = configuration.selectionMode === "random" ? "random" : "shuffle"
  var fingerprint = collectionFingerprint(quotes)
  var selection = restoredSelection(quotes, mode, fingerprint, options.persistedState)
  var collectionError = options.collectionError || null
  var configurationError = options.configurationError || null
  var stateError = options.stateError || null
  var shouldPersist = false

  if (!selection) {
    selection = initialSelection(quotes, mode, options.randomValues)
    if (options.persistedState && !stateError)
      stateError = "Persisted state is incompatible with the Quote Collection"
    shouldPersist = quotes.length > 0 || Boolean(options.persistedState) || Boolean(stateError)
  }

  var errorSequences = Object.assign({}, options.errorSequences || ({}))
  var errorSequence = Number(options.errorSequence || 0)
  var initialErrors = {
    collectionError: collectionError,
    configurationError: configurationError,
    stateError: stateError
  }
  for (var errorIndex = 0; errorIndex < reportedErrorFields.length; errorIndex++) {
    var errorField = reportedErrorFields[errorIndex]
    if (initialErrors[errorField] && !errorSequences[errorField]) {
      errorSequence += 1
      errorSequences[errorField] = errorSequence
    }
  }
  var initialErrorSource = latestErrorSource(initialErrors, errorSequences)

  var model = {
    activeQuote: selection.activeIndex >= 0 ? quotes[selection.activeIndex] : null,
    activeQuoteIndex: selection.activeIndex,
    advanceCount: 0,
    advanceOnWallpaperChange: configuration.advanceOnWallpaperChange !== false,
    automaticAdvancePaused: false,
    collectionFingerprint: fingerprint,
    collectionError: collectionError,
    collectionKind: options.collectionKind || "bundled",
    collectionSize: quotes.length,
    configurationError: configurationError,
    configuredVisibility: configuration.visible !== false,
    errorSequence: errorSequence,
    errorSequences: errorSequences,
    health: stateError ? "degraded-state" : "healthy",
    intervalError: null,
    intervalMinutes: Number(configuration.intervalMinutes || 0),
    lastError: initialErrorSource ? initialErrors[initialErrorSource] : null,
    lastErrorSource: initialErrorSource,
    presentationError: null,
    presentationHistory: [],
    presentationHistoryIndex: -1,
    presentationOverflow: false,
    quotes: quotes,
    runtimeVisibility: configuration.visible !== false,
    selectionMode: mode,
    shuffleRemaining: selection.shuffleRemaining,
    stateError: stateError,
    wallpaperAvailable: false,
    wallpaperBaseline: null,
    wallpaperError: null
  }

  if (model.activeQuoteIndex >= 0) {
    model.presentationHistory = [currentSelectionSnapshot(model)]
    model.presentationHistoryIndex = 0
  }

  var effects = effectsForSelection(model, shouldPersist, false)
  if (model.intervalMinutes > 0) effects.push(restartIntervalEffect(model))
  return { model: model, effects: effects }
}

function reloadCollection(model, collection, options) {
  options = options || ({})
  var quotes = collection && Array.isArray(collection.quotes) ? collection.quotes : []
  var fingerprint = collectionFingerprint(quotes)
  var collectionKind = options.collectionKind || "user"
  if (fingerprint === model.collectionFingerprint && collectionKind === model.collectionKind &&
      sameQuoteCollections(quotes, model.quotes)) {
    var effects = intervalRestartEffects(model)
    return {
      model: model.collectionError
        ? withReportedHealth(model, { collectionError: null })
        : model,
      effects: effects
    }
  }
  var activeIndex = findQuoteIndex(quotes, model.activeQuote)
  var selection

  if (activeIndex >= 0) {
    selection = {
      activeIndex: activeIndex,
      shuffleRemaining: model.selectionMode === "shuffle"
        ? shuffleWithoutActive(quotes, activeIndex, options.randomValues)
        : []
    }
  } else {
    selection = initialSelection(quotes, model.selectionMode, options.randomValues)
  }

  var history = remapPresentationHistory(model, quotes, selection, activeIndex >= 0)

  var nextModel = withReportedHealth(model, {
    activeQuote: selection.activeIndex >= 0 ? quotes[selection.activeIndex] : null,
    activeQuoteIndex: selection.activeIndex,
    collectionError: null,
    collectionFingerprint: fingerprint,
    collectionKind: collectionKind,
    collectionSize: quotes.length,
    presentationHistory: history.entries,
    presentationHistoryIndex: history.index,
    quotes: quotes,
    shuffleRemaining: selection.shuffleRemaining
  })

  var effects = effectsForSelection(nextModel, true, true)
  effects = effects.concat(intervalRestartEffects(nextModel))
  return { model: nextModel, effects: effects }
}

function remappedShuffleRemaining(model, quotes, quoteIndexes, entry, activeQuoteIndex) {
  var remapped = []
  var seen = ({})
  for (var index = 0; index < entry.shuffleRemaining.length; index++) {
    var oldQuote = model.quotes[entry.shuffleRemaining[index]]
    var identity = quoteIdentity(oldQuote)
    var newIndex = Object.prototype.hasOwnProperty.call(quoteIndexes, identity)
      ? quoteIndexes[identity] : -1
    if (newIndex < 0 || newIndex === activeQuoteIndex || seen[newIndex]) continue
    remapped.push(newIndex)
    seen[newIndex] = true
  }
  return remapped
}

function remapPresentationHistory(model, quotes, selection, activePreserved) {
  if (!activePreserved) {
    if (selection.activeIndex < 0) return { entries: [], index: -1 }
    return {
      entries: [selectionSnapshot(
        selection.activeIndex,
        selection.shuffleRemaining,
        quotes[selection.activeIndex]
      )],
      index: 0
    }
  }

  var entries = []
  var historyIndex = -1
  var quoteIndexes = quoteIndexByIdentity(quotes)
  for (var index = 0; index < model.presentationHistory.length; index++) {
    var entry = model.presentationHistory[index]
    var newIndex = Object.prototype.hasOwnProperty.call(quoteIndexes, entry.quoteIdentity)
      ? quoteIndexes[entry.quoteIdentity] : -1
    if (newIndex < 0) continue
    entries.push(selectionSnapshot(
      newIndex,
      model.selectionMode === "shuffle"
        ? remappedShuffleRemaining(model, quotes, quoteIndexes, entry, newIndex)
        : [],
      quotes[newIndex]
    ))
    if (index <= model.presentationHistoryIndex) historyIndex = entries.length - 1
  }

  if (historyIndex < 0 || entries[historyIndex].activeQuoteIndex !== selection.activeIndex) {
    return {
      entries: [selectionSnapshot(
        selection.activeIndex,
        selection.shuffleRemaining,
        quotes[selection.activeIndex]
      )],
      index: 0
    }
  }
  entries[historyIndex] = selectionSnapshot(
    selection.activeIndex,
    selection.shuffleRemaining,
    quotes[selection.activeIndex]
  )
  return { entries: entries, index: historyIndex }
}

function collectionReloadFailed(model, message) {
  return {
    model: withReportedHealth(model, {
      collectionError: String(message || "User Collection could not be loaded")
    }),
    effects: []
  }
}

function reloadConfiguration(model, configuration, randomValues) {
  var mode = configuration.selectionMode === "random" ? "random" : "shuffle"
  var modeChanged = mode !== model.selectionMode
  var shuffleRemaining = model.shuffleRemaining
  var presentationHistory = model.presentationHistory
  if (modeChanged) {
    shuffleRemaining = mode === "shuffle"
      ? shuffleWithoutActive(model.quotes, model.activeQuoteIndex, randomValues)
      : []
    presentationHistory = model.presentationHistory.map(function(entry) {
      var entryShuffleRemaining = mode === "shuffle"
        ? shuffleWithoutActive(model.quotes, entry.activeQuoteIndex, randomValues)
        : []
      return selectionSnapshot(
        entry.activeQuoteIndex,
        entryShuffleRemaining,
        model.quotes[entry.activeQuoteIndex]
      )
    })
  }

  var nextModel = withReportedHealth(model, {
    advanceOnWallpaperChange: configuration.advanceOnWallpaperChange !== false,
    automaticAdvancePaused: false,
    configurationError: null,
    configuredVisibility: configuration.visible !== false,
    intervalMinutes: Number(configuration.intervalMinutes || 0),
    presentationHistory: presentationHistory,
    runtimeVisibility: configuration.visible !== false,
    selectionMode: mode,
    shuffleRemaining: shuffleRemaining
  })
  var effects = modeChanged && nextModel.quotes.length > 0
    ? [{
          type: "persist-state",
          state: stateFor(nextModel),
          recoverHealthOnSave: true
        }]
    : []
  effects.push(restartIntervalEffect(nextModel))
  return { model: nextModel, effects: effects }
}

function configurationReloadFailed(model, message) {
  return {
    model: withReportedHealth(model, {
      configurationError: String(message || "Configuration could not be loaded")
    }),
    effects: []
  }
}

function setRuntimeVisibility(model, visible) {
  var runtimeVisibility = Boolean(visible)
  if (model.runtimeVisibility === runtimeVisibility) return { model: model, effects: [] }
  return {
    model: Object.assign({}, model, { runtimeVisibility: runtimeVisibility }),
    effects: []
  }
}

function toggleRuntimeVisibility(model) {
  return setRuntimeVisibility(model, !model.runtimeVisibility)
}

function nextShuffleSelection(model, randomValues) {
  var remaining = model.shuffleRemaining.slice()
  if (remaining.length === 0) {
    remaining = shuffledIndices(model.quotes.length, randomValues)
    if (remaining.length > 1 && remaining[0] === model.activeQuoteIndex) {
      var replacement = remaining[0]
      remaining[0] = remaining[1]
      remaining[1] = replacement
    }
  }
  return { activeIndex: remaining.shift(), shuffleRemaining: remaining }
}

function nextRandomSelection(model, randomValues) {
  if (model.quotes.length <= 1)
    return { activeIndex: model.quotes.length === 1 ? 0 : -1, shuffleRemaining: [] }

  var alternatives = []
  for (var index = 0; index < model.quotes.length; index++) {
    if (index !== model.activeQuoteIndex) alternatives.push(index)
  }
  return {
    activeIndex: alternatives[randomIndex(alternatives.length, randomAt(randomValues, 0))],
    shuffleRemaining: []
  }
}

function sameIndices(left, right) {
  if (left.length !== right.length) return false
  for (var index = 0; index < left.length; index++) {
    if (left[index] !== right[index]) return false
  }
  return true
}

function restoreHistorySelection(model, historyIndex, source) {
  var entry = model.presentationHistory[historyIndex]
  var nextModel = Object.assign({}, model, {
    activeQuote: entry.activeQuoteIndex >= 0 ? model.quotes[entry.activeQuoteIndex] : null,
    activeQuoteIndex: entry.activeQuoteIndex,
    presentationHistoryIndex: historyIndex,
    shuffleRemaining: entry.shuffleRemaining.slice()
  })
  if (source) {
    nextModel.advanceCount = model.advanceCount + 1
    nextModel.lastAdvanceSource = source
  }
  var effects = effectsForSelection(nextModel, nextModel.activeQuote !== null, true)
  effects = effects.concat(intervalRestartEffects(nextModel))
  return { model: nextModel, effects: effects }
}

function canGoPrevious(model) {
  return model.collectionSize > 1 && model.presentationHistoryIndex > 0
}

function canGoForward(model) {
  return model.collectionSize > 1 && model.presentationHistoryIndex >= 0
}

function automaticAdvanceAvailable(model) {
  return model.collectionSize > 0 &&
    (model.advanceOnWallpaperChange === true || model.intervalMinutes > 0)
}

function previous(model) {
  if (!canGoPrevious(model)) return { model: model, effects: [] }
  return restoreHistorySelection(model, model.presentationHistoryIndex - 1, null)
}

function pauseAutomaticAdvance(model) {
  if (model.automaticAdvancePaused) return { model: model, effects: [] }
  return {
    model: Object.assign({}, model, { automaticAdvancePaused: true }),
    effects: [{ type: "stop-interval" }]
  }
}

function resumeAutomaticAdvance(model) {
  if (!model.automaticAdvancePaused) return { model: model, effects: [] }
  var nextModel = Object.assign({}, model, { automaticAdvancePaused: false })
  return {
    model: nextModel,
    effects: nextModel.intervalMinutes > 0 ? [restartIntervalEffect(nextModel)] : []
  }
}

function toggleAutomaticAdvancePause(model) {
  return model.automaticAdvancePaused
    ? resumeAutomaticAdvance(model)
    : pauseAutomaticAdvance(model)
}

function isAutomaticAdvanceSource(source) {
  return source === "interval" || source === "wallpaper"
}

function advance(model, randomValues, source) {
  if (model.automaticAdvancePaused && isAutomaticAdvanceSource(source))
    return { model: model, effects: [] }
  if (model.presentationHistoryIndex >= 0 &&
      model.presentationHistoryIndex < model.presentationHistory.length - 1)
    return restoreHistorySelection(
      model,
      model.presentationHistoryIndex + 1,
      source || "explicit"
    )

  var selection = model.selectionMode === "random"
    ? nextRandomSelection(model, randomValues)
    : nextShuffleSelection(model, randomValues)
  var nextModel = Object.assign({}, model, {
    activeQuote: selection.activeIndex >= 0 ? model.quotes[selection.activeIndex] : null,
    activeQuoteIndex: selection.activeIndex,
    advanceCount: model.advanceCount + 1,
    lastAdvanceSource: source || "explicit",
    shuffleRemaining: selection.shuffleRemaining
  })
  var selectionChanged = selection.activeIndex !== model.activeQuoteIndex ||
    !sameIndices(selection.shuffleRemaining, model.shuffleRemaining)

  if (selection.activeIndex !== model.activeQuoteIndex) {
    nextModel.presentationHistory = model.presentationHistory.concat([
      selectionSnapshot(
        selection.activeIndex,
        selection.shuffleRemaining,
        model.quotes[selection.activeIndex]
      )
    ])
    if (nextModel.presentationHistory.length > maximumPresentationHistoryEntries)
      nextModel.presentationHistory = nextModel.presentationHistory.slice(
        nextModel.presentationHistory.length - maximumPresentationHistoryEntries
      )
    nextModel.presentationHistoryIndex = nextModel.presentationHistory.length - 1
  }

  var effects = effectsForSelection(nextModel, nextModel.quotes.length > 0 && selectionChanged, true)
  effects = effects.concat(intervalRestartEffects(nextModel))
  return { model: nextModel, effects: effects }
}

function observeWallpaper(model, canonicalPath, randomValues) {
  var path = String(canonicalPath)
  if (model.wallpaperBaseline === null || model.wallpaperBaseline === undefined) {
    return {
      model: withReportedHealth(model, {
        wallpaperAvailable: true,
        wallpaperBaseline: path,
        wallpaperError: null
      }),
      effects: []
    }
  }
  if (model.wallpaperBaseline === path) return {
    model: withReportedHealth(model, {
      wallpaperAvailable: true,
      wallpaperError: null
    }),
    effects: []
  }

  if (!model.advanceOnWallpaperChange) return {
    model: withReportedHealth(model, {
      wallpaperAvailable: true,
      wallpaperBaseline: path,
      wallpaperError: null
    }),
    effects: []
  }

  var result = advance(model, randomValues, "wallpaper")
  result.model = withReportedHealth(result.model, {
    wallpaperAvailable: true,
    wallpaperBaseline: path,
    wallpaperError: null
  })
  return result
}

function wallpaperUnavailable(model, message) {
  var errorMessage = String(message || "Wallpaper target is unavailable")
  if (!model.wallpaperAvailable && model.wallpaperError === errorMessage)
    return { model: model, effects: [] }
  return {
    model: withReportedHealth(model, {
      wallpaperAvailable: false,
      wallpaperError: errorMessage
    }),
    effects: []
  }
}

function setPresentationOverflow(model, overflowing) {
  var presentationOverflow = Boolean(overflowing)
  if (model.presentationOverflow === presentationOverflow)
    return { model: model, effects: [] }
  return {
    model: withReportedHealth(model, {
      presentationError: presentationOverflow
        ? "Quote Presentation overflow remains after Text Fit" : null,
      presentationOverflow: presentationOverflow
    }),
    effects: []
  }
}

function intervalFailed(model, message) {
  return {
    model: withReportedHealth(model, {
      intervalError: String(message || "Interval could not be restarted")
    }),
    effects: []
  }
}

function intervalSucceeded(model) {
  if (!model.intervalError) return { model: model, effects: [] }
  return {
    model: withReportedHealth(model, { intervalError: null }),
    effects: []
  }
}

function persistenceFailed(model, message) {
  return {
    model: withReportedHealth(model, {
      stateError: String(message || "Persisted state could not be written")
    }),
    effects: []
  }
}

function persistenceSucceeded(model) {
  if (!model.stateError) return { model: model, effects: [] }
  return {
    model: withReportedHealth(model, { stateError: null }),
    effects: []
  }
}

function runtimeStatus(model) {
  return JSON.stringify({
    health: model.health,
    configuredVisibility: model.configuredVisibility,
    runtimeVisibility: model.runtimeVisibility,
    advanceOnWallpaperChange: model.advanceOnWallpaperChange,
    automaticAdvancePaused: model.automaticAdvancePaused,
    canGoForward: canGoForward(model),
    canGoPrevious: canGoPrevious(model),
    collectionKind: model.collectionKind,
    collectionSize: model.collectionSize,
    intervalMinutes: model.intervalMinutes,
    selectionMode: model.selectionMode,
    activeQuote: copiedQuote(model.activeQuote),
    presentationOverflow: model.presentationOverflow,
    wallpaperAvailable: model.wallpaperAvailable,
    lastError: model.lastError
  })
}

function startingRuntimeStatus(configuration, errors, errorSequences) {
  errors = errors || ({})
  var lastErrorSource = latestErrorSource(errors, errorSequences || ({}))
  return JSON.stringify({
    health: "starting",
    configuredVisibility: configuration.visible !== false,
    runtimeVisibility: configuration.visible !== false,
    advanceOnWallpaperChange: configuration.advanceOnWallpaperChange !== false,
    automaticAdvancePaused: false,
    canGoForward: false,
    canGoPrevious: false,
    collectionKind: "bundled",
    collectionSize: 0,
    intervalMinutes: Number(configuration.intervalMinutes || 0),
    selectionMode: configuration.selectionMode === "random" ? "random" : "shuffle",
    activeQuote: null,
    presentationOverflow: false,
    lastError: lastErrorSource ? errors[lastErrorSource] : null
  })
}
