import { useState, useEffect } from "react";
import axios from "axios";

const API_URL = import.meta.env.VITE_API_URL || "http://localhost:5000";

const CATEGORIES = [
  { name: "Food", color: "#f7b955" },
  { name: "Transport", color: "#60a5fa" },
  { name: "Shopping", color: "#c084fc" },
  { name: "Bills", color: "#f87171" },
  { name: "Entertainment", color: "#34d399" },
  { name: "Health", color: "#f472b6" },
  { name: "Other", color: "#94a3b8" },
];

const currency = new Intl.NumberFormat("en-US", {
  style: "currency",
  currency: "USD",
});

const categoryColor = (name) => {
  const match = CATEGORIES.find((c) => c.name === name);
  return match ? match.color : CATEGORIES[CATEGORIES.length - 1].color;
};

function App() {
  const [expenses, setExpenses] = useState([]);
  const [description, setDescription] = useState("");
  const [amount, setAmount] = useState("");
  const [category, setCategory] = useState("Food");
  const [editingId, setEditingId] = useState(null);
  const [filter, setFilter] = useState("all");
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);

  // Fetch all expenses on mount
  useEffect(() => {
    fetchExpenses();
  }, []);

  const fetchExpenses = async () => {
    try {
      setLoading(true);
      setError(null);
      const res = await axios.get(`${API_URL}/api/expenses`);
      setExpenses(res.data);
    } catch (err) {
      setError("Failed to load expenses. Make sure the backend server is running.");
      console.error(err);
    } finally {
      setLoading(false);
    }
  };

  const resetForm = () => {
    setDescription("");
    setAmount("");
    setCategory("Food");
    setEditingId(null);
  };

  const handleSubmit = async (e) => {
    e.preventDefault();
    if (!description.trim() || !amount) return;

    try {
      setError(null);
      const payload = { description, amount: Number(amount), category };
      if (editingId) {
        await axios.patch(`${API_URL}/api/expenses/${editingId}`, payload);
      } else {
        await axios.post(`${API_URL}/api/expenses`, payload);
      }
      resetForm();
      fetchExpenses();
    } catch (err) {
      setError("Failed to save expense. Please try again.");
      console.error(err);
    }
  };

  const handleEdit = (expense) => {
    setEditingId(expense._id);
    setDescription(expense.description);
    setAmount(String(expense.amount));
    setCategory(expense.category);
    window.scrollTo({ top: 0, behavior: "smooth" });
  };

  const handleDelete = async (id) => {
    try {
      setError(null);
      await axios.delete(`${API_URL}/api/expenses/${id}`);
      fetchExpenses();
    } catch (err) {
      setError("Failed to delete expense.");
      console.error(err);
    }
  };

  const usedCategories = [...new Set(expenses.map((e) => e.category))];

  // Reset the category filter if its category no longer exists
  // (e.g. the last expense of that category was deleted)
  useEffect(() => {
    if (filter !== "all" && !usedCategories.includes(filter)) {
      setFilter("all");
    }
  }, [filter, usedCategories]);

  const filtered =
    filter === "all" ? expenses : expenses.filter((e) => e.category === filter);
  const total = filtered.reduce((sum, e) => sum + e.amount, 0);
  const average = filtered.length ? total / filtered.length : 0;

  return (
    <div className="app">
      <header className="header">
        <h1>💸 Expense Tracker</h1>
        <p className="subtitle">Keep tabs on where your money goes</p>
      </header>

      <main className="main">
        {/* Error banner */}
        {error && (
          <div className="error-banner" onClick={() => setError(null)}>
            {error}
          </div>
        )}

        {/* Add / edit form */}
        <form className="add-form" onSubmit={handleSubmit}>
          <input
            type="text"
            className="input"
            placeholder="What did you spend on?"
            value={description}
            onChange={(e) => setDescription(e.target.value)}
            required
            autoFocus
          />
          <input
            type="number"
            className="input amount"
            placeholder="0.00"
            min="0"
            step="0.01"
            value={amount}
            onChange={(e) => setAmount(e.target.value)}
            required
          />
          <select
            className="input select"
            value={category}
            onChange={(e) => setCategory(e.target.value)}
          >
            {CATEGORIES.map((c) => (
              <option key={c.name} value={c.name}>
                {c.name}
              </option>
            ))}
          </select>
          <button type="submit" className="btn btn-add">
            {editingId ? "Save" : "+ Add"}
          </button>
          {editingId && (
            <button
              type="button"
              className="btn btn-cancel"
              onClick={resetForm}
            >
              Cancel
            </button>
          )}
        </form>

        {editingId && (
          <p className="editing-hint">✏️ Editing expense — changes apply on save</p>
        )}

        {/* Loading state */}
        {loading && <p className="status-text">Loading your expenses…</p>}

        {/* Empty state */}
        {!loading && expenses.length === 0 && (
          <p className="status-text">
            No expenses yet. Add your first one above!
          </p>
        )}

        {!loading && expenses.length > 0 && (
          <>
            {/* Stats */}
            <div className="stats">
              <div className="stat-card">
                <span className="stat-label">Total</span>
                <span className="stat-value total">{currency.format(total)}</span>
              </div>
              <div className="stat-card">
                <span className="stat-label">Expenses</span>
                <span className="stat-value">{filtered.length}</span>
              </div>
              <div className="stat-card">
                <span className="stat-label">Average</span>
                <span className="stat-value">{currency.format(average)}</span>
              </div>
            </div>

            {/* Category filter chips */}
            <div className="toolbar">
              <div className="filters">
                <button
                  className={`filter-btn ${filter === "all" ? "active" : ""}`}
                  onClick={() => setFilter("all")}
                >
                  All
                </button>
                {usedCategories.map((name) => (
                  <button
                    key={name}
                    className={`filter-btn ${filter === name ? "active" : ""}`}
                    onClick={() => setFilter(name)}
                  >
                    <span
                      className="dot"
                      style={{ background: categoryColor(name) }}
                    />
                    {name}
                  </button>
                ))}
              </div>
            </div>

            {/* Expense list */}
            {filtered.length === 0 ? (
              <p className="status-text">
                No expenses in this category yet.
              </p>
            ) : (
              <ul className="expense-list">
                {filtered.map((expense) => (
                  <li key={expense._id} className="expense">
                    <div className="expense-info">
                      <span className="expense-description">
                        {expense.description}
                      </span>
                      <span
                        className="category-badge"
                        style={{
                          background: `${categoryColor(expense.category)}1f`,
                          color: categoryColor(expense.category),
                          borderColor: `${categoryColor(expense.category)}4d`,
                        }}
                      >
                        {expense.category}
                      </span>
                    </div>
                    <div className="expense-actions">
                      <span className="expense-amount">
                        {currency.format(expense.amount)}
                      </span>
                      <button
                        className="btn btn-edit"
                        onClick={() => handleEdit(expense)}
                        title="Edit expense"
                      >
                        ✎
                      </button>
                      <button
                        className="btn btn-delete"
                        onClick={() => handleDelete(expense._id)}
                        title="Delete expense"
                      >
                        ✕
                      </button>
                    </div>
                  </li>
                ))}
              </ul>
            )}
          </>
        )}
      </main>
    </div>
  );
}

export default App;
