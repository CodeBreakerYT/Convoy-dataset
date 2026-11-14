# Bike image dataset

Transparent-background PNGs of motorcycles, grouped by brand, for the bike picker in the app.
Images are loaded straight from this repo at runtime, so they add nothing to the app size.

## Layout

```
bike/
├── README.md
├── <Brand>/
│   └── <Brand> <Model> <Year>.png
```

- One folder per brand = one category in the app (Hero, Honda, Royal Enfield, Suzuki, TVS, Yamaha).
- File name (without `.png`) is the label shown in the app.
- Only `bike/<Brand>/<file>.png|jpg|jpeg|webp` is read. Anything else (README, deeper folders) is ignored.
- Repo must be **public** so the app can fetch the images without a token.

## Adding bikes

1. Drop the PNG into `bike/<Brand>/` (create the folder for a new brand).
2. Name it `Brand Model Year.png`.
3. `git add bike && git commit -m "add bikes" && git push`

No manifest to update. The app lists the repo tree itself.

## Using it in the app (SwiftUI)

Add `BikeGalleryGitHub.swift` (in the root of this repo) to the Xcode project, edit the two lines at the top:

```swift
let githubRepoLink = "https://github.com/<your-username>/<this-repo>"
let imagesFolder   = "bike"
```

Then show `BikeGalleryView()`. It lists categories from the folder names, filters by category, has search, and caches every image after the first download.

### How the URLs work

- File list: `https://api.github.com/repos/<owner>/<repo>/git/trees/HEAD?recursive=1`
  (60 unauthenticated calls/hour per IP; the app caches the list for 1 hour and falls back to the last saved list).
- Image: `https://raw.githubusercontent.com/<owner>/<repo>/HEAD/bike/<Brand>/<file>.png`
  (spaces are percent-encoded, e.g. `Royal%20Enfield`).

## Notes

- Keep file names unique and consistent; renaming a file changes its label in the app.
- If the list ever shows empty: check the repo is public, `imagesFolder` matches the folder name, and files sit exactly one level deep (`bike/<Brand>/<file>`).
