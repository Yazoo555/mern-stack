const mongoose = require("mongoose");

const expenseSchema = new mongoose.Schema(
  {
    description: {
      type: String,
      required: [true, "Description is required"],
      trim: true,
    },
    amount: {
      type: Number,
      required: [true, "Amount is required"],
      min: [0, "Amount must be positive"],
    },
    category: {
      type: String,
      trim: true,
      default: "Other",
    },
  },
  { timestamps: true }
);

module.exports = mongoose.model("Expense", expenseSchema);
