const Expense = require("../models/Expense");

// GET /api/expenses
const getExpenses = async (req, res) => {
  try {
    const expenses = await Expense.find().sort({ createdAt: -1 });
    res.status(200).json(expenses);
  } catch (error) {
    res.status(500).json({ message: error.message });
  }
};

// POST /api/expenses
const createExpense = async (req, res) => {
  try {
    const description =
      typeof req.body.description === "string" ? req.body.description.trim() : "";
    const category =
      typeof req.body.category === "string" ? req.body.category.trim() : "";
    const { amount } = req.body;

    if (description === "") {
      return res.status(400).json({ message: "Description is required" });
    }

    const parsedAmount = Number(amount);
    if (!Number.isFinite(parsedAmount) || parsedAmount <= 0) {
      return res.status(400).json({ message: "Amount must be a positive number" });
    }

    const expense = await Expense.create({
      description,
      amount: Math.round(parsedAmount * 100) / 100,
      category: category || "Other",
    });
    res.status(201).json(expense);
  } catch (error) {
    res.status(500).json({ message: error.message });
  }
};

// PATCH /api/expenses/:id (update description, amount, and/or category)
const updateExpense = async (req, res) => {
  try {
    const expense = await Expense.findById(req.params.id);

    if (!expense) {
      return res.status(404).json({ message: "Expense not found" });
    }

    const { amount } = req.body;

    if (req.body.description !== undefined) {
      const description =
        typeof req.body.description === "string"
          ? req.body.description.trim()
          : "";
      if (description === "") {
        return res.status(400).json({ message: "Description cannot be empty" });
      }
      expense.description = description;
    }

    if (amount !== undefined) {
      const parsedAmount = Number(amount);
      if (!Number.isFinite(parsedAmount) || parsedAmount <= 0) {
        return res
          .status(400)
          .json({ message: "Amount must be a positive number" });
      }
      expense.amount = Math.round(parsedAmount * 100) / 100;
    }

    if (req.body.category !== undefined) {
      const category =
        typeof req.body.category === "string" ? req.body.category.trim() : "";
      expense.category = category || "Other";
    }

    await expense.save();
    res.status(200).json(expense);
  } catch (error) {
    res.status(500).json({ message: error.message });
  }
};

// DELETE /api/expenses/:id
const deleteExpense = async (req, res) => {
  try {
    const expense = await Expense.findByIdAndDelete(req.params.id);

    if (!expense) {
      return res.status(404).json({ message: "Expense not found" });
    }

    res.status(200).json({ message: "Expense deleted successfully" });
  } catch (error) {
    res.status(500).json({ message: error.message });
  }
};

module.exports = {
  getExpenses,
  createExpense,
  updateExpense,
  deleteExpense,
};
