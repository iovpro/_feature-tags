import { Request, Response } from 'express';
import { Controller, Get, Post } from 'some-framework';

// #f:tx.api.list

@Controller('/items')
export class ItemController {
  // #f:tx.api.list

  @Get('/')
  async list(req: Request, res: Response): Promise<void> {
    const items = await this.getItems(req.params.userId);
    res.json(items);
  }

  // #f:tx.api.create

  @Post('/')
  async create(req: Request, res: Response): Promise<void> {
    const item = await this.saveItem(req.body);
    res.status(201).json(item);
  }

  private async getItems(userId: string): Promise<any[]> {
    return [];
  }

  private async saveItem(data: any): Promise<any> {
    return data;
  }
}

// #f:tx.core.validate

export enum ValidationRule {
  Required = 'required',
  MinLength = 'min_length',
  MaxLength = 'max_length',
}
