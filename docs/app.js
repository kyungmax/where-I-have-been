const DEFAULT_DATA_URL = "./data/trips.json";
const SAMPLE_DATA_URL = "./data/trips.sample.json";

const state = {
  dataset: null,
  selectedYear: "all",
  activeVisitId: null,
  map: null,
  markerLayer: null,
  markersById: new Map(),
};

const refs = {
  totalPhotos: document.getElementById("stat-total-photos"),
  geotaggedPhotos: document.getElementById("stat-geotagged-photos"),
  visitAreas: document.getElementById("stat-visit-areas"),
  countries: document.getElementById("stat-countries"),
  yearFilters: document.getElementById("year-filters"),
  visitList: document.getElementById("visit-list"),
  generatedAt: document.getElementById("generated-at"),
  mapSummary: document.getElementById("map-summary"),
  statusLine: document.getElementById("status-line"),
  jsonUpload: document.getElementById("json-upload"),
  loadSample: document.getElementById("load-sample"),
};

function escapeHtml(value) {
  return String(value).replace(/[&<>"']/g, (character) => {
    const entities = {
      "&": "&amp;",
      "<": "&lt;",
      ">": "&gt;",
      '"': "&quot;",
      "'": "&#39;",
    };

    return entities[character] ?? character;
  });
}

function formatNumber(value) {
  return new Intl.NumberFormat("ko-KR").format(value ?? 0);
}

function formatDateTime(value) {
  if (!value) {
    return "알 수 없음";
  }

  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return value;
  }

  return new Intl.DateTimeFormat("ko-KR", {
    year: "numeric",
    month: "short",
    day: "numeric",
  }).format(date);
}

function formatRange(start, end) {
  if (!start && !end) {
    return "날짜 정보 없음";
  }
  if (start === end) {
    return formatDateTime(start);
  }
  return `${formatDateTime(start)} - ${formatDateTime(end)}`;
}

function collectYears(dataset) {
  const years = new Set();
  for (const visit of dataset.visits ?? []) {
    for (const date of visit.visitDates ?? []) {
      if (typeof date === "string" && date.length >= 4) {
        years.add(date.slice(0, 4));
      }
    }
  }
  return Array.from(years).sort((a, b) => Number(b) - Number(a));
}

function getFilteredVisits() {
  if (!state.dataset) {
    return [];
  }

  const visits = state.dataset.visits ?? [];
  if (state.selectedYear === "all") {
    return visits;
  }

  return visits.filter((visit) =>
    (visit.visitDates ?? []).some((date) => String(date).startsWith(state.selectedYear)),
  );
}

function ensureMap() {
  if (state.map) {
    return;
  }

  state.map = L.map("map", {
    zoomControl: true,
    worldCopyJump: true,
  }).setView([30, 10], 2);

  L.tileLayer("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png", {
    attribution:
      '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors',
    maxZoom: 19,
  }).addTo(state.map);

  state.markerLayer = L.layerGroup().addTo(state.map);
}

function buildPopupHtml(visit, photosById) {
  const photoItems = (visit.photoIds ?? [])
    .slice(0, 5)
    .map((photoId) => photosById.get(photoId))
    .filter(Boolean)
    .map(
      (photo) =>
        `<li>${escapeHtml(photo.localDate)} · ${escapeHtml(photo.filename)}</li>`,
    )
    .join("");

  return `
    <div class="visit-popup">
      <h3>${escapeHtml(visit.locationLabel ?? "Unknown")}</h3>
      <p>${escapeHtml(formatRange(visit.firstVisitedAt, visit.lastVisitedAt))}</p>
      <p>${formatNumber(visit.visitCount)}회 방문 · 사진 ${formatNumber(visit.photoCount)}장</p>
      ${photoItems ? `<ul>${photoItems}</ul>` : ""}
    </div>
  `;
}

function buildMarker(visit, photosById) {
  const multipleVisits = Number(visit.visitCount) > 1;
  const className = multipleVisits ? "visit-marker multi" : "visit-marker";
  const markerHtml = `<div class="${className}">${escapeHtml(visit.visitCount)}</div>`;
  const icon = L.divIcon({
    className: "visit-marker-wrapper",
    html: markerHtml,
    iconSize: multipleVisits ? [50, 50] : [42, 42],
    iconAnchor: multipleVisits ? [25, 25] : [21, 21],
    popupAnchor: [0, -18],
  });

  const marker = L.marker([visit.latitude, visit.longitude], { icon });
  marker.bindPopup(buildPopupHtml(visit, photosById));
  marker.on("click", () => {
    state.activeVisitId = visit.id;
    renderVisitList();
  });
  return marker;
}

function renderMap() {
  ensureMap();
  state.markerLayer.clearLayers();
  state.markersById.clear();

  const visits = getFilteredVisits();
  const photosById = new Map((state.dataset?.photos ?? []).map((photo) => [photo.id, photo]));
  const bounds = [];

  for (const visit of visits) {
    const marker = buildMarker(visit, photosById);
    state.markerLayer.addLayer(marker);
    state.markersById.set(visit.id, marker);
    bounds.push([visit.latitude, visit.longitude]);
  }

  if (bounds.length > 0) {
    state.map.fitBounds(bounds, {
      padding: [36, 36],
      maxZoom: 7,
    });
  } else {
    state.map.setView([30, 10], 2);
  }

  refs.mapSummary.textContent =
    bounds.length > 0
      ? `${formatNumber(bounds.length)}개 방문 지역을 지도에 표시 중`
      : "표시할 방문 기록이 없습니다.";
}

function renderStats() {
  const summary = state.dataset?.summary ?? {};
  refs.totalPhotos.textContent = formatNumber(summary.totalPhotos);
  refs.geotaggedPhotos.textContent = formatNumber(summary.geotaggedPhotos);
  refs.visitAreas.textContent = formatNumber(summary.visitAreas);
  refs.countries.textContent = formatNumber((summary.countries ?? []).length);

  const generatedAt = state.dataset?.generatedAt;
  refs.generatedAt.textContent = generatedAt
    ? `생성 시각: ${formatDateTime(generatedAt)}`
    : "생성 시각 없음";
}

function renderYearFilters() {
  const years = collectYears(state.dataset ?? { visits: [] });
  const options = ["all", ...years];

  refs.yearFilters.innerHTML = "";
  for (const option of options) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = `year-chip${state.selectedYear === option ? " active" : ""}`;
    button.textContent = option === "all" ? "전체" : option;
    button.addEventListener("click", () => {
      state.selectedYear = option;
      renderYearFilters();
      renderMap();
      renderVisitList();
    });
    refs.yearFilters.appendChild(button);
  }
}

function focusVisit(visitId) {
  const visit = (state.dataset?.visits ?? []).find((item) => item.id === visitId);
  const marker = state.markersById.get(visitId);
  if (!visit || !marker) {
    return;
  }

  state.activeVisitId = visitId;
  state.map.flyTo([visit.latitude, visit.longitude], Math.max(state.map.getZoom(), 6), {
    duration: 0.8,
  });
  marker.openPopup();
  renderVisitList();
}

function renderVisitList() {
  const visits = [...getFilteredVisits()].sort((left, right) => {
    if (left.lastVisitedAt === right.lastVisitedAt) {
      return left.locationLabel.localeCompare(right.locationLabel);
    }
    return left.lastVisitedAt < right.lastVisitedAt ? 1 : -1;
  });

  refs.visitList.innerHTML = "";

  if (visits.length === 0) {
    refs.visitList.innerHTML = `
      <div class="empty-state">
        아직 표시할 방문 기록이 없습니다. 먼저 <code>swift scripts/build_trip_data.swift</code>로
        <code>docs/data/trips.json</code>을 생성하거나, 샘플 데이터를 불러오세요.
      </div>
    `;
    return;
  }

  for (const visit of visits) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = `visit-card${state.activeVisitId === visit.id ? " active" : ""}`;
    button.innerHTML = `
      <span class="visit-card-title">${escapeHtml(visit.locationLabel ?? "Unknown")}</span>
      <span class="visit-card-meta">${formatNumber(visit.visitCount)}회 방문 · 사진 ${formatNumber(visit.photoCount)}장</span>
      <span class="visit-card-dates">${escapeHtml(formatRange(visit.firstVisitedAt, visit.lastVisitedAt))}</span>
    `;
    button.addEventListener("click", () => focusVisit(visit.id));
    refs.visitList.appendChild(button);
  }
}

function normaliseDataset(dataset) {
  return {
    generatedAt: dataset.generatedAt ?? null,
    sourceDirectory: dataset.sourceDirectory ?? "",
    settings: dataset.settings ?? {},
    summary: dataset.summary ?? {
      totalPhotos: (dataset.photos ?? []).length,
      geotaggedPhotos: (dataset.photos ?? []).filter(
        (photo) => photo.latitude != null && photo.longitude != null,
      ).length,
      unlocatedPhotos: 0,
      visitAreas: (dataset.visits ?? []).length,
      countries: [],
      years: [],
    },
    photos: Array.isArray(dataset.photos) ? dataset.photos : [],
    visits: Array.isArray(dataset.visits) ? dataset.visits : [],
  };
}

function applyDataset(dataset, statusMessage) {
  state.dataset = normaliseDataset(dataset);
  state.selectedYear = "all";
  state.activeVisitId = state.dataset.visits?.[0]?.id ?? null;
  refs.statusLine.textContent = statusMessage;
  renderStats();
  renderYearFilters();
  renderMap();
  renderVisitList();
}

async function fetchJson(url) {
  const response = await fetch(url, { cache: "no-store" });
  if (!response.ok) {
    throw new Error(`${url} loading failed (${response.status})`);
  }
  return response.json();
}

async function loadDefaultDataset() {
  if (window.location.protocol === "file:") {
    applyDataset(
      {
        generatedAt: null,
        summary: {
          totalPhotos: 0,
          geotaggedPhotos: 0,
          unlocatedPhotos: 0,
          visitAreas: 0,
          countries: [],
          years: [],
        },
        photos: [],
        visits: [],
      },
      "브라우저에서 파일을 직접 열면 JSON fetch가 막힐 수 있습니다. GitHub Pages 또는 로컬 HTTP 서버로 열어주세요.",
    );
    return;
  }

  try {
    const data = await fetchJson(DEFAULT_DATA_URL);
    if ((data.photos ?? []).length > 0 || (data.visits ?? []).length > 0) {
      applyDataset(data, "docs/data/trips.json을 불러왔습니다.");
      return;
    }
  } catch (error) {
    console.warn(error);
  }

  const emptyDataset = {
    generatedAt: null,
    summary: {
      totalPhotos: 0,
      geotaggedPhotos: 0,
      unlocatedPhotos: 0,
      visitAreas: 0,
      countries: [],
      years: [],
    },
    photos: [],
    visits: [],
  };
  applyDataset(
    emptyDataset,
    "docs/data/trips.json이 비어 있습니다. 스크립트로 데이터를 생성하거나 샘플을 불러오세요.",
  );
}

async function loadSampleDataset() {
  const sample = await fetchJson(SAMPLE_DATA_URL);
  applyDataset(sample, "샘플 데이터를 불러왔습니다.");
}

function handleFileUpload(event) {
  const [file] = event.target.files ?? [];
  if (!file) {
    return;
  }

  const reader = new FileReader();
  reader.onload = () => {
    try {
      const parsed = JSON.parse(String(reader.result));
      applyDataset(parsed, `${file.name} 파일을 브라우저에서 불러왔습니다.`);
    } catch (error) {
      refs.statusLine.textContent = `JSON 파싱 실패: ${error.message}`;
    }
  };
  reader.readAsText(file);
  event.target.value = "";
}

async function boot() {
  refs.jsonUpload.addEventListener("change", handleFileUpload);
  refs.loadSample.addEventListener("click", async () => {
    try {
      await loadSampleDataset();
    } catch (error) {
      refs.statusLine.textContent = `샘플 데이터 로드 실패: ${error.message}`;
    }
  });

  await loadDefaultDataset();
}

boot().catch((error) => {
  refs.statusLine.textContent = `초기화 실패: ${error.message}`;
});
