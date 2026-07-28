# AI Panel Integration

- Toggle the AI panel with the toolbar button (sparkles icon).
- Ask questions about the current page; the app extracts visible text via JavaScript and sends it as context.
- Implementation uses `SimpleAIService` with three backends:
  - Cloud Shortcuts (clipboard-based response).
  - Apple local (FoundationModels / Apple Intelligence).
  - MLX local (mlx-swift + mlx-swift-lm).

MLX requires the MLX Swift packages and Apple Silicon; configure the model id and token limits in the AI panel.
