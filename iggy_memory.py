"""
iggy_memory.py — IGGY's long-term memory.

ChromaDB vector store. The crawler feeds text here continuously.
IGGY retrieves relevant chunks before every response — this is what
makes her knowledge *hers*, not a generic model's.

Also stores conversation history so IGGY remembers past interactions.
"""

import json, hashlib
from pathlib import Path
from datetime import datetime
from typing import List, Optional

import chromadb
from chromadb.utils import embedding_functions
from sentence_transformers import SentenceTransformer

MEMORY_DIR = Path("iggy_memory_store")
EMBED_MODEL = "all-MiniLM-L6-v2"   # 80MB, fast, CPU-friendly

class IggyMemory:
    def __init__(self):
        MEMORY_DIR.mkdir(exist_ok=True)
        print(f"[Memory] Initializing ChromaDB at {MEMORY_DIR}...")

        self.client = chromadb.PersistentClient(path=str(MEMORY_DIR))
        self.embedder = SentenceTransformer(EMBED_MODEL)

        # Two collections: knowledge (crawled) + conversations
        self.knowledge = self.client.get_or_create_collection(
            name="iggy_knowledge",
            metadata={"hnsw:space": "cosine"},
        )
        self.conversations = self.client.get_or_create_collection(
            name="iggy_conversations",
            metadata={"hnsw:space": "cosine"},
        )

        print(f"[Memory] ✅ Ready. Knowledge chunks: {self.knowledge.count()} | Conversations: {self.conversations.count()}")

    # ── Store ──────────────────────────────────────────────────────────────────
    def store_knowledge(self, text: str, source: str = "", topic: str = ""):
        """Store a crawled text chunk into IGGY's knowledge base."""
        if not text or len(text.strip()) < 50:
            return

        # Deduplicate by content hash
        content_hash = hashlib.md5(text.encode()).hexdigest()
        existing = self.knowledge.get(ids=[content_hash])
        if existing["ids"]:
            return  # already stored

        embedding = self.embedder.encode(text).tolist()
        self.knowledge.add(
            ids=[content_hash],
            embeddings=[embedding],
            documents=[text],
            metadatas=[{
                "source": source,
                "topic": topic,
                "timestamp": datetime.utcnow().isoformat(),
                "length": len(text),
            }]
        )

    def store_conversation(self, user_msg: str, iggy_msg: str):
        """Store a conversation turn so IGGY remembers past interactions."""
        ts = datetime.utcnow().isoformat()
        uid = hashlib.md5(f"{ts}{user_msg}".encode()).hexdigest()
        text = f"User: {user_msg}\nIGGY: {iggy_msg}"
        embedding = self.embedder.encode(text).tolist()
        self.conversations.add(
            ids=[uid],
            embeddings=[embedding],
            documents=[text],
            metadatas=[{"timestamp": ts}]
        )

    # ── Retrieve ───────────────────────────────────────────────────────────────
    def retrieve(self, query: str, n: int = 5, include_conversations: bool = False) -> List[str]:
        """
        Retrieve the most relevant knowledge chunks for a query.
        This is what gets injected into IGGY's context window.
        """
        results = []
        if self.knowledge.count() > 0:
            q_embed = self.embedder.encode(query).tolist()
            hits = self.knowledge.query(
                query_embeddings=[q_embed],
                n_results=min(n, self.knowledge.count()),
                include=["documents", "metadatas"],
            )
            for doc, meta in zip(hits["documents"][0], hits["metadatas"][0]):
                src = meta.get("source", "")
                results.append(f"[{src}] {doc[:400]}" if src else doc[:400])

        if include_conversations and self.conversations.count() > 0:
            q_embed = self.embedder.encode(query).tolist()
            hits = self.conversations.query(
                query_embeddings=[q_embed],
                n_results=min(3, self.conversations.count()),
                include=["documents"],
            )
            results.extend(hits["documents"][0])

        return results

    def stats(self) -> dict:
        return {
            "knowledge_chunks": self.knowledge.count(),
            "conversation_turns": self.conversations.count(),
        }

    def search_by_topic(self, topic: str, n: int = 10) -> List[dict]:
        """Filter knowledge by topic tag."""
        return self.knowledge.get(
            where={"topic": topic},
            limit=n,
            include=["documents", "metadatas"],
        )
