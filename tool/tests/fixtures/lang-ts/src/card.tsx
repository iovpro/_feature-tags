import React from 'react';

// #f:tx.ui.card@entry

export const Card: React.FC<{ title: string; amount: number }> = ({ title, amount }) => {
  return (
    <div className="card">
      <h2>{title}</h2>
      <span>{amount}</span>
    </div>
  );
};
