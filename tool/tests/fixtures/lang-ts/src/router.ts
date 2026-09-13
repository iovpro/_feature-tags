import { Request, Response } from 'express';

// #f:tx.api.list@operation

export function routeAction(action: string, req: Request, res: Response): void {
  switch (action) {
    case 'list': // #f:tx.api.list
      res.json([]);
      break;
    case 'create': // #f:tx.api.create
      res.status(201).json({});
      break;
    default: // #f:tx.core.validate
      res.status(400).json({ error: 'unknown action' });
      break;
  }
}
