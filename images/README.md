# Architecture Diagrams

This directory contains architecture diagrams for the TID installation guide.

## Generating Diagrams

The `.mermaid` files can be converted to images using:

1. **Mermaid CLI**:
   ```bash
   npm install -g @mermaid-js/mermaid-cli
   mmdc -i ca-rotation-architecture.mermaid -o ca-rotation-architecture.png
   ```

2. **Online Tools**:
   - [Mermaid Live Editor](https://mermaid.live/)
   - Copy the content from `.mermaid` files
   - Export as PNG/SVG

## Diagrams

- `ca-rotation-architecture.mermaid`: Shows the complete certificate hierarchy and rotation flow