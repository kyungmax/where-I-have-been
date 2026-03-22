# Where I Have Been

iPhone 사진 디렉토리를 읽어서 촬영 날짜와 GPS 메타데이터를 추출하고, 방문 기록을 JSON으로 정리한 뒤 전세계 지도에 그려주는 정적 웹앱입니다.

결과물은 GitHub Pages에서 그대로 서빙할 수 있게 `docs/` 폴더 기준으로 구성되어 있습니다.

## 포함된 것

- `scripts/build_trip_data.swift`
  - 사진 디렉토리를 재귀적으로 읽어서 `docs/data/trips.json` 생성
  - 기본 동작은 기존 JSON에 신규/변경 사진을 `upsert`
  - 가까운 좌표를 하나의 방문 지역으로 묶고, 서로 다른 날짜 수를 `n회 방문`으로 계산
  - 필요하면 OpenStreetMap Nominatim으로 역지오코딩해서 지역 이름까지 붙임
- `docs/index.html`
  - GitHub Pages용 단일 페이지 UI
- `docs/app.js`
  - JSON 로딩, 연도 필터, 지도 마커, 방문 리스트 렌더링
- `docs/data/trips.json`
  - 실제 데이터가 들어갈 파일
- `docs/data/trips.sample.json`
  - UI 확인용 샘플 데이터

## 기본 흐름

1. iPhone 사진을 한 디렉토리에 모읍니다.
2. Swift 스크립트로 사진 메타데이터를 읽어 `docs/data/trips.json`에 upsert합니다.
3. `docs/`를 GitHub Pages로 배포하면 웹에서 바로 볼 수 있습니다.

## 사진 JSON 생성

```bash
swift scripts/build_trip_data.swift \
  --input "/Users/yourname/Pictures/TravelPhotos" \
  --output docs/data/trips.json
```

기본값:

- 방문 지역 병합 거리: `250m`
- 역지오코딩: 켜짐
- 출력 파일: `docs/data/trips.json`
- 기존 `docs/data/trips.json`이 있으면 새 사진을 여기에 upsert

자주 쓰는 옵션:

```bash
swift scripts/build_trip_data.swift \
  --input "/Users/yourname/Pictures/TravelPhotos" \
  --output docs/data/trips.json \
  --distance-meters 400 \
  --no-reverse-geocode
```

옵션 설명:

- `--distance-meters`
  - 서로 가까운 좌표를 같은 방문 지역으로 취급할 반경입니다.
- `--replace`
  - 기존 JSON을 무시하고 현재 입력 디렉토리만으로 처음부터 다시 만듭니다.
- `--no-reverse-geocode`
  - 네트워크 없이 좌표만 유지하고 싶을 때 사용합니다.
- `--geocode-delay`
  - 역지오코딩 호출 간 간격입니다. 기본값은 `1.1`초입니다.

추가 참고:

- 기본 동작은 upsert입니다. 이번 실행에서 스캔하지 않은 기존 사진은 삭제하지 않습니다.
- 같은 사진을 다시 스캔하면 경로 정보와 메타데이터를 기준으로 기존 레코드를 갱신합니다.
- 역지오코딩 결과는 `docs/data/geocode-cache.json`에 캐시됩니다.
- GPS가 없는 사진은 JSON에는 남지만 지도에는 올라가지 않습니다.
- 일부 메신저/클라우드 내보내기 과정은 EXIF를 지워버릴 수 있습니다. 이 경우 원본 사진 폴더를 쓰는 편이 낫습니다.
- 현재 스크립트는 이미지 파일 중심입니다. Live Photo의 동영상(`.MOV`)은 처리하지 않습니다.

## JSON 구조

생성 결과는 대략 아래 형태입니다.

```json
{
  "generatedAt": "2026-03-22T20:10:00.000+09:00",
  "sourceDirectories": ["/Users/yourname/Pictures/TravelPhotos"],
  "summary": {
    "totalPhotos": 120,
    "geotaggedPhotos": 93,
    "visitAreas": 18
  },
  "photos": [
    {
      "filename": "IMG_1234.HEIC",
      "capturedAt": "2025-06-01T14:22:10.000+09:00",
      "latitude": 48.8584,
      "longitude": 2.2945,
      "clusterId": "visit-abc123"
    }
  ],
  "visits": [
    {
      "locationLabel": "Paris, Ile-de-France, France",
      "visitCount": 2,
      "photoCount": 7,
      "visitDates": ["2025-06-01", "2025-06-03"]
    }
  ]
}
```

## 로컬 확인

브라우저에서 `index.html` 파일을 직접 열면 `fetch` 제한 때문에 JSON 로딩이 막힐 수 있습니다. 간단한 로컬 서버로 확인하는 편이 안전합니다.

```bash
python3 -m http.server 4173 --directory docs
```

그 다음 브라우저에서 `http://localhost:4173`로 접속하면 됩니다.

## GitHub Pages 배포

이 저장소는 `docs/` 폴더를 바로 Pages 소스로 쓰는 구성을 전제로 만들어져 있습니다.

1. `docs/data/trips.json`을 생성합니다.
   - 이후 신규 사진이 생기면 같은 명령을 다시 실행하면 됩니다. 기본값이 upsert입니다.
2. 변경사항을 커밋하고 GitHub에 푸시합니다.
3. GitHub 저장소의 `Settings > Pages`로 이동합니다.
4. 배포 소스를 브랜치 방식으로 설정하고, 브랜치는 `main`, 폴더는 `/docs`를 선택합니다.
5. 저장 후 배포가 끝나면 GitHub Pages URL에서 지도를 확인합니다.

`.nojekyll` 파일은 이미 포함되어 있어서 정적 파일이 Jekyll 처리 없이 배포됩니다.

## UI 특징

- 전세계 지도 위에 방문 지역을 핀으로 표시
- 같은 장소를 여러 날 방문하면 `n`으로 묶어서 표시
- 연도 필터 제공
- 오른쪽 패널에서 방문 타임라인 확인
- 생성한 JSON 대신 브라우저에서 다른 JSON 파일을 직접 올려서 미리보기 가능
